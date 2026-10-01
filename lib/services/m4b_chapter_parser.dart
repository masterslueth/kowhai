import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/audiobook.dart';

/// Parses chapter metadata from M4B (MP4 audiobook) files.
///
/// Supports two chapter formats:
///   • Nero `chpl` box (less common)
///   • QuickTime chapter track (iTunes / Audible)
class M4bChapterParser {
  static void _log(String msg) => debugPrint('[Kowhai:M4bParser] $msg');

  /// Ceiling on a single box payload slurped into memory. A truncated or
  /// crafted MP4 can declare a box size of 0x7FFFFFFF; without this cap
  /// `_readBox` would allocate gigabytes from a 20-byte file.
  static const int _maxBoxBytes = 16 * 1024 * 1024;

  /// Ceiling on the number of sample-table entries expanded in memory. The
  /// `stts` run count and `stsz` sample count are raw uint32 values from the
  /// file, so a corrupt value near 2^32 would otherwise OOM the isolate.
  /// Every sample needs at least one byte of media data, so this is far above
  /// any legitimate audiobook while bounding the blast radius.
  static const int _maxSamples = 8 * 1000 * 1000;

  /// Entry point: tries Nero `chpl` first, then QuickTime chapter track.
  static Future<List<Chapter>> parseChapters(String filePath) async {
    RandomAccessFile? raf;
    try {
      raf = await File(filePath).open();
      final fileSize = await raf.length();

      // Try Nero chpl (less common)
      final nero = await _scanForChpl(raf, 0, fileSize);
      if (nero.isNotEmpty) {
        // Box order is not guaranteed to be chronological — normalise.
        nero.sort((a, b) => a.start.compareTo(b.start));
        _log('    M4B chapters (Nero): ${nero.length}');
        return nero;
      }

      // Try QuickTime chapter track (iTunes / Audible format)
      final qt = await _parseQTChapters(raf, fileSize);
      if (qt.isNotEmpty) {
        // Sample/chunk tables can yield out-of-order titles on odd muxes.
        qt.sort((a, b) => a.start.compareTo(b.start));
      }
      _log('    M4B chapters (QT): ${qt.length}');
      return qt;
    } catch (e) {
      _log('    M4B chapter parse error: $e');
      return const [];
    } finally {
      await raf?.close();
    }
  }

  // ── Shared MP4 box utilities ──────────────────────────────────────────────

  /// Returns all direct child boxes within [start, end] as (type, dataStart, boxEnd).
  static Future<List<(String, int, int)>> _listBoxes(
      RandomAccessFile raf, int start, int end) async {
    final result = <(String, int, int)>[];
    var pos = start;
    while (pos + 8 <= end) {
      await raf.setPosition(pos);
      final hdr = await raf.read(8);
      if (hdr.length < 8) break;
      final bd = ByteData.sublistView(Uint8List.fromList(hdr));
      var sz = bd.getUint32(0, Endian.big);
      final type = String.fromCharCodes(hdr.sublist(4, 8));
      int dataStart = pos + 8;
      if (sz == 1) {
        final ext = await raf.read(8);
        if (ext.length < 8) break;
        final ebd = ByteData.sublistView(Uint8List.fromList(ext));
        sz = (ebd.getUint32(0, Endian.big) << 32) | ebd.getUint32(4, Endian.big);
        dataStart = pos + 16;
      } else if (sz == 0) {
        sz = end - pos;
      }
      if (sz < 8) break;
      result.add((type, dataStart, pos + sz));
      pos += sz;
    }
    return result;
  }

  /// First box matching [type] in [boxes], or null.
  static (String, int, int)? _firstBox(List<(String, int, int)> boxes, String type) {
    for (final b in boxes) {
      if (b.$1 == type) return b;
    }
    return null;
  }

  /// Reads the data portion of [box] into memory, clamped to [_maxBoxBytes].
  ///
  /// [box]'s end offset comes from the box's own size field, which a corrupt
  /// file can inflate arbitrarily. The read is capped so a hostile or truncated
  /// M4B degrades into "no chapters" (the caller is try/caught) instead of an
  /// out-of-memory crash.
  static Future<Uint8List> _readBox(RandomAccessFile raf, (String, int, int) box) async {
    final declared = box.$3 - box.$2;
    if (declared <= 0) return Uint8List(0);
    final len = declared > _maxBoxBytes ? _maxBoxBytes : declared;
    await raf.setPosition(box.$2);
    return Uint8List.fromList(await raf.read(len));
  }

  // ── Nero chpl format ──────────────────────────────────────────────────────

  static Future<List<Chapter>> _scanForChpl(
      RandomAccessFile raf, int start, int end) async {
    final boxes = await _listBoxes(raf, start, end);
    for (final box in boxes) {
      if (box.$1 == 'chpl') {
        return _parseChpl(await _readBox(raf, box));
      }
      if (box.$1 == 'moov' || box.$1 == 'udta') {
        final result = await _scanForChpl(raf, box.$2, box.$3);
        if (result.isNotEmpty) return result;
      } else if (box.$1 == 'meta') {
        // `meta` is a FullBox: 4 bytes of version/flags sit between the box
        // header and its child boxes (ISO/IEC 14496-12). Some legacy writers
        // omit them, so try the standard layout first, then the raw payload.
        final std = await _scanForChpl(raf, box.$2 + 4, box.$3);
        if (std.isNotEmpty) return std;
        final result = await _scanForChpl(raf, box.$2, box.$3);
        if (result.isNotEmpty) return result;
      }
    }
    return const [];
  }

  static List<Chapter> _parseChpl(Uint8List data) {
    if (data.length < 9) return const [];
    final bd = ByteData.sublistView(data);
    int offset = 5; // version(1) + flags(3) + reserved(1)
    if (offset + 4 > data.length) return const [];
    final count = bd.getUint32(offset, Endian.big);
    offset += 4;
    final chapters = <Chapter>[];
    for (int i = 0; i < count; i++) {
      if (offset + 9 > data.length) break;
      final hi = bd.getUint32(offset, Endian.big);
      final lo = bd.getUint32(offset + 4, Endian.big);
      final units100ns = (hi << 32) | lo;
      offset += 8;
      final titleLen = data[offset++];
      if (offset + titleLen > data.length) break;
      chapters.add(Chapter(
        title: utf8.decode(data.sublist(offset, offset + titleLen),
            allowMalformed: true),
        start: Duration(microseconds: units100ns ~/ 10),
      ));
      offset += titleLen;
    }
    return chapters;
  }

  // ── QuickTime chapter track format ────────────────────────────────────────
  //
  // iTunes M4B files store chapters as a separate text `trak` identified by
  // a `gmhd` (generic media header) inside its `minf`. The audio trak has a
  // `tref/chap` reference pointing to this track. Chapter timestamps come
  // from `stts` (time-to-sample table) and titles are text samples read via
  // `stco` (chunk offsets) + `stsz` (sample sizes).

  static Future<List<Chapter>> _parseQTChapters(
      RandomAccessFile raf, int fileSize) async {
    final top = await _listBoxes(raf, 0, fileSize);
    final moov = _firstBox(top, 'moov');
    if (moov == null) return const [];

    final moovBoxes = await _listBoxes(raf, moov.$2, moov.$3);
    for (final box in moovBoxes) {
      if (box.$1 != 'trak') continue;
      final chapters = await _tryQTChapterTrak(raf, box);
      if (chapters.isNotEmpty) return chapters;
    }
    return const [];
  }

  static Future<List<Chapter>> _tryQTChapterTrak(
      RandomAccessFile raf, (String, int, int) trak) async {
    final trakBoxes = await _listBoxes(raf, trak.$2, trak.$3);
    final mdia = _firstBox(trakBoxes, 'mdia');
    if (mdia == null) return const [];

    final mdiaBoxes = await _listBoxes(raf, mdia.$2, mdia.$3);
    final mdhd = _firstBox(mdiaBoxes, 'mdhd');
    final minf = _firstBox(mdiaBoxes, 'minf');
    if (mdhd == null || minf == null) return const [];

    final minfBoxes = await _listBoxes(raf, minf.$2, minf.$3);
    // gmhd = generic media header; present in chapter/text tracks
    if (_firstBox(minfBoxes, 'gmhd') == null) return const [];

    final stbl = _firstBox(minfBoxes, 'stbl');
    if (stbl == null) return const [];

    final stblBoxes = await _listBoxes(raf, stbl.$2, stbl.$3);
    final stts = _firstBox(stblBoxes, 'stts');
    final stsz = _firstBox(stblBoxes, 'stsz');
    final stco = _firstBox(stblBoxes, 'stco');
    final co64 = _firstBox(stblBoxes, 'co64');
    final stsc = _firstBox(stblBoxes, 'stsc');
    if (stts == null || stsz == null || (stco == null && co64 == null)) {
      return const [];
    }

    return await _extractQTChapters(raf, mdhd, stts, stsz, stco ?? co64!, stsc,
        isco64: stco == null);
  }

  static Future<List<Chapter>> _extractQTChapters(
    RandomAccessFile raf,
    (String, int, int) mdhd,
    (String, int, int) stts,
    (String, int, int) stsz,
    (String, int, int) stco,
    (String, int, int)? stsc, {
    bool isco64 = false,
  }) async {
    final mdhdData = await _readBox(raf, mdhd);
    final sttsData = await _readBox(raf, stts);
    final stszData = await _readBox(raf, stsz);
    final stcoData = await _readBox(raf, stco);
    final stscData = stsc != null ? await _readBox(raf, stsc) : null;

    // Time scale from mdhd (version 0: offset 12; version 1: offset 20)
    final mdhdBD = ByteData.sublistView(mdhdData);
    final timeScale = mdhdBD.getUint32(mdhdData[0] == 1 ? 20 : 12, Endian.big);
    if (timeScale == 0) return const [];

    // Sample start times from stts (time-to-sample table)
    final sttsBD = ByteData.sublistView(sttsData);
    final sttsCount = sttsBD.getUint32(4, Endian.big);
    final sampleStarts = <int>[];
    int ticks = 0, off = 8;
    for (int i = 0; i < sttsCount && off + 8 <= sttsData.length; i++) {
      final n = sttsBD.getUint32(off, Endian.big);     // sample count in run
      final d = sttsBD.getUint32(off + 4, Endian.big); // duration per sample
      // `n` is an unvalidated uint32 from the file: bound the expansion so a
      // corrupt run length cannot allocate gigabytes of List<int>.
      final remaining = _maxSamples - sampleStarts.length;
      if (remaining <= 0) break;
      for (int j = 0; j < n && j < remaining; j++) {
        sampleStarts.add(ticks);
        ticks += d;
      }
      off += 8;
    }

    // Sample sizes from stsz
    final stszBD = ByteData.sublistView(stszData);
    final defSz = stszBD.getUint32(4, Endian.big);
    final declaredSampleCount = stszBD.getUint32(8, Endian.big);
    // Unvalidated uint32: `List.filled(0xFFFFFFFF, …)` is an instant OOM.
    final sampleCount =
        declaredSampleCount > _maxSamples ? _maxSamples : declaredSampleCount;
    final sizes = <int>[];
    if (defSz == 0) {
      off = 12;
      for (int i = 0; i < sampleCount && off + 4 <= stszData.length; i++, off += 4) {
        sizes.add(stszBD.getUint32(off, Endian.big));
      }
    } else {
      sizes.addAll(List.filled(sampleCount, defSz));
    }

    // Chunk file offsets from stco (32-bit) or co64 (64-bit)
    final stcoBD = ByteData.sublistView(stcoData);
    final chunkCount = stcoBD.getUint32(4, Endian.big);
    final chunkOffsets = <int>[];
    off = 8;
    if (isco64) {
      for (int i = 0; i < chunkCount && off + 8 <= stcoData.length; i++, off += 8) {
        final hi = stcoBD.getUint32(off, Endian.big);
        final lo = stcoBD.getUint32(off + 4, Endian.big);
        chunkOffsets.add((hi << 32) | lo);
      }
    } else {
      for (int i = 0; i < chunkCount && off + 4 <= stcoData.length; i++, off += 4) {
        chunkOffsets.add(stcoBD.getUint32(off, Endian.big));
      }
    }

    // Map sample index → file offset using stsc (sample-to-chunk table)
    final sampleOffsets = <int>[];
    if (stscData != null && stscData.length >= 8) {
      final stscBD = ByteData.sublistView(stscData);
      final stscCount = stscBD.getUint32(4, Endian.big);
      // Each stsc entry: firstChunk(4) + samplesPerChunk(4) + descIndex(4)
      final runs = <(int, int)>[]; // (firstChunk 0-based, samplesPerChunk)
      off = 8;
      for (int i = 0; i < stscCount && off + 12 <= stscData.length; i++, off += 12) {
        runs.add((stscBD.getUint32(off, Endian.big) - 1,
                  stscBD.getUint32(off + 4, Endian.big)));
      }
      int sIdx = 0;
      for (int c = 0; c < chunkOffsets.length; c++) {
        // Find samples-per-chunk for this chunk from the run table
        int spc = 1;
        for (int e = runs.length - 1; e >= 0; e--) {
          if (c >= runs[e].$1) { spc = runs[e].$2; break; }
        }
        int chunkOff = chunkOffsets[c];
        for (int j = 0; j < spc && sIdx < sizes.length; j++, sIdx++) {
          sampleOffsets.add(chunkOff);
          chunkOff += sizes[sIdx];
        }
      }
    } else {
      // No stsc: assume one sample per chunk
      sampleOffsets.addAll(chunkOffsets.take(sizes.length));
    }

    // Read each chapter text sample and build Chapter list
    final chapters = <Chapter>[];
    for (int i = 0;
        i < sizes.length && i < sampleOffsets.length && i < sampleStarts.length;
        i++) {
      await raf.setPosition(sampleOffsets[i]);
      final data = await raf.read(sizes[i]);
      if (data.length < 3) continue;

      // QuickTime text sample: 2-byte big-endian length + UTF-8 string
      final len = (data[0] << 8) | data[1];
      if (len == 0 || 2 + len > data.length) continue;

      final titleBytes = data.sublist(2, 2 + len);
      String title;
      try {
        title = utf8.decode(titleBytes);
      } catch (_) {
        // Fall back to UTF-16BE
        final chars = <int>[];
        for (int j = 0; j + 1 < titleBytes.length; j += 2) {
          chars.add((titleBytes[j] << 8) | titleBytes[j + 1]);
        }
        title = String.fromCharCodes(chars);
      }

      chapters.add(Chapter(
        title: title,
        start: Duration(microseconds: sampleStarts[i] * 1000000 ~/ timeScale),
      ));
    }
    return chapters;
  }
}
