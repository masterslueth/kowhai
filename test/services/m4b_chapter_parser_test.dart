import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:kowhai/services/m4b_chapter_parser.dart';

/// Builds a minimal MP4 box: 4-byte big-endian size + 4-byte type + [data].
Uint8List _box(String type, Uint8List data) {
  final size = 8 + data.length;
  final buf = ByteData(8);
  buf.setUint32(0, size, Endian.big);
  final header = Uint8List(8);
  for (int i = 0; i < 8; i++) { header[i] = buf.getUint8(i); }
  header[4] = type.codeUnitAt(0);
  header[5] = type.codeUnitAt(1);
  header[6] = type.codeUnitAt(2);
  header[7] = type.codeUnitAt(3);
  return Uint8List.fromList([...header, ...data]);
}

/// Wraps [inner] in a container box of the given [type].
Uint8List _containerBox(String type, List<Uint8List> children) {
  final inner = children.expand((c) => c).toList();
  return _box(type, Uint8List.fromList(inner));
}

/// Builds a Nero `chpl` box payload with the given chapter entries.
/// Each entry: 8-byte timestamp (100ns units) + 1-byte title length + title.
Uint8List _buildChplPayload(List<(Duration, String)> chapters) {
  final buf = BytesBuilder();
  // version (1 byte) + flags (3 bytes) + reserved (1 byte)
  buf.add([0, 0, 0, 0, 0]);
  // chapter count (4 bytes big-endian)
  final countBuf = ByteData(4);
  countBuf.setUint32(0, chapters.length, Endian.big);
  buf.add(countBuf.buffer.asUint8List());
  for (final (dur, title) in chapters) {
    // Timestamp in 100ns units
    final units100ns = dur.inMicroseconds * 10;
    final tsBuf = ByteData(8);
    tsBuf.setUint32(0, (units100ns >> 32) & 0xFFFFFFFF, Endian.big);
    tsBuf.setUint32(4, units100ns & 0xFFFFFFFF, Endian.big);
    buf.add(tsBuf.buffer.asUint8List());
    // Title length + title bytes
    final titleBytes = title.codeUnits;
    buf.addByte(titleBytes.length);
    buf.add(titleBytes);
  }
  return buf.toBytes();
}

/// Writes [bytes] to a temp file and returns the path.
Future<String> _writeTempFile(Directory dir, Uint8List bytes) async {
  final file = File('${dir.path}/test.m4b');
  await file.writeAsBytes(bytes);
  return file.path;
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('m4b_parser_test_');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  group('M4bChapterParser — Nero chpl format', () {
    test('parses chapters from a minimal moov/udta/chpl structure', () async {
      final chplData = _buildChplPayload([
        (Duration.zero, 'Intro'),
        (const Duration(minutes: 5), 'Chapter 1'),
        (const Duration(minutes: 15, seconds: 30), 'Chapter 2'),
      ]);
      final chplBox = _box('chpl', chplData);
      final udtaBox = _containerBox('udta', [chplBox]);
      final moovBox = _containerBox('moov', [udtaBox]);
      // Add a minimal ftyp box before moov (standard MP4 structure).
      final ftypBox = _box('ftyp', Uint8List.fromList([
        // brand "M4B " + version 0
        0x4D, 0x34, 0x42, 0x20, 0x00, 0x00, 0x00, 0x00,
      ]));
      final fileBytes = Uint8List.fromList([...ftypBox, ...moovBox]);
      final path = await _writeTempFile(tempDir, fileBytes);

      final chapters = await M4bChapterParser.parseChapters(path);

      expect(chapters.length, 3);
      expect(chapters[0].title, 'Intro');
      expect(chapters[0].start, Duration.zero);
      expect(chapters[1].title, 'Chapter 1');
      expect(chapters[1].start, const Duration(minutes: 5));
      expect(chapters[2].title, 'Chapter 2');
      expect(chapters[2].start, const Duration(minutes: 15, seconds: 30));
    });

    test('returns empty list for truncated chpl payload', () async {
      // chpl box with only 3 bytes of data (too short for header)
      final chplBox = _box('chpl', Uint8List.fromList([0, 0, 0]));
      final udtaBox = _containerBox('udta', [chplBox]);
      final moovBox = _containerBox('moov', [udtaBox]);
      final path = await _writeTempFile(tempDir, moovBox);

      final chapters = await M4bChapterParser.parseChapters(path);
      expect(chapters, isEmpty);
    });

    test('parses chpl nested inside a FullBox meta container', () async {
      // iTunes-style layout: moov/udta/meta/chpl where `meta` carries a
      // 4-byte version/flags header between its own header and its children.
      final chplData = _buildChplPayload([
        (Duration.zero, 'Intro'),
        (const Duration(minutes: 5), 'Chapter 1'),
      ]);
      final chplBox = _box('chpl', chplData);
      final metaPayload =
          Uint8List.fromList([0, 0, 0, 0, ...chplBox]); // FullBox header
      final metaBox = _box('meta', metaPayload);
      final udtaBox = _containerBox('udta', [metaBox]);
      final moovBox = _containerBox('moov', [udtaBox]);
      final path = await _writeTempFile(tempDir, moovBox);

      final chapters = await M4bChapterParser.parseChapters(path);

      expect(chapters.length, 2);
      expect(chapters[0].title, 'Intro');
      expect(chapters[1].title, 'Chapter 1');
    });

    test('sorts out-of-order chpl entries chronologically', () async {
      final chplData = _buildChplPayload([
        (const Duration(minutes: 15), 'Late'),
        (Duration.zero, 'First'),
        (const Duration(minutes: 5), 'Middle'),
      ]);
      final chplBox = _box('chpl', chplData);
      final udtaBox = _containerBox('udta', [chplBox]);
      final moovBox = _containerBox('moov', [udtaBox]);
      final path = await _writeTempFile(tempDir, moovBox);

      final chapters = await M4bChapterParser.parseChapters(path);

      expect(
          chapters.map((c) => c.title).toList(), ['First', 'Middle', 'Late']);
    });
  });

  group('M4bChapterParser — edge cases', () {
    test('returns empty list for a non-MP4 file', () async {
      final path = await _writeTempFile(
          tempDir, Uint8List.fromList('not an mp4 file at all'.codeUnits));

      final chapters = await M4bChapterParser.parseChapters(path);
      expect(chapters, isEmpty);
    });

    test('returns empty list for an empty file', () async {
      final path = await _writeTempFile(tempDir, Uint8List(0));

      final chapters = await M4bChapterParser.parseChapters(path);
      expect(chapters, isEmpty);
    });

    test('returns empty list for a non-existent file', () async {
      final chapters = await M4bChapterParser.parseChapters(
          '${tempDir.path}/does_not_exist.m4b');
      expect(chapters, isEmpty);
    });

    test('returns empty list for moov with no chapter data', () async {
      // moov box with only a mvhd-like dummy box, no udta/chpl/trak
      final dummyBox = _box('mvhd', Uint8List(100));
      final moovBox = _containerBox('moov', [dummyBox]);
      final path = await _writeTempFile(tempDir, moovBox);

      final chapters = await M4bChapterParser.parseChapters(path);
      expect(chapters, isEmpty);
    });

    // ── Malformed input hardening ───────────────────────────────────────────
    //
    // Box sizes and table counts come straight from the file. Before the caps
    // these were unvalidated uint32s, so a tiny crafted file could force a
    // multi-gigabyte allocation and OOM the isolate mid-scan.

    test('box declaring a huge size does not trigger a huge allocation',
        () async {
      // A `chpl` box header claiming ~2 GiB of payload in a ~16 byte file.
      final header = Uint8List(8);
      final bd = ByteData.sublistView(header);
      bd.setUint32(0, 0x7FFFFFFF, Endian.big);
      header[4] = 'c'.codeUnitAt(0);
      header[5] = 'h'.codeUnitAt(0);
      header[6] = 'p'.codeUnitAt(0);
      header[7] = 'l'.codeUnitAt(0);

      final path = await _writeTempFile(tempDir, header);
      final chapters = await M4bChapterParser.parseChapters(path);
      expect(chapters, isEmpty);
    });

    test('stsz sample count near 2^32 is clamped', () async {
      // moov > trak > (mdhd, stsz with sample_count = 0xFFFFFFFF)
      final mdhd = _box('mdhd', _buildMdhd());
      final stsz = _box('stsz', _buildStsz(0xFFFFFFFF, 0));
      final stts = _box('stts', _buildStts(0xFFFFFFFF, 1024));
      final stco = _box('stco', _buildChunkTable(0));
      final minf = _containerBox('minf', [mdhd, stsz, stts, stco]);
      final gmhd = _containerBox('gmhd', [_box('chap', Uint8List(0))]);
      final trak = _containerBox('trak', [gmhd, minf]);
      final moov = _containerBox('moov', [trak]);

      final path = await _writeTempFile(tempDir, moov);
      // Completing without an OOM is the assertion.
      final chapters = await M4bChapterParser.parseChapters(path);
      expect(chapters, isEmpty);
    });

    test('stts run length near 2^32 does not expand billions of entries',
        () async {
      final mdhd = _box('mdhd', _buildMdhd());
      // One run declaring 0xFFFFFFFF samples at a nonzero delta.
      final stts = _box('stts', _buildStts(1, 1024, runCount: 0xFFFFFFFF));
      final stsz = _box('stsz', _buildStsz(16, 1024));
      final stco = _box('stco', _buildChunkTable(1));
      final minf = _containerBox('minf', [mdhd, stsz, stts, stco]);
      final gmhd = _containerBox('gmhd', [_box('chap', Uint8List(0))]);
      final trak = _containerBox('trak', [gmhd, minf]);
      final moov = _containerBox('moov', [trak]);

      final path = await _writeTempFile(tempDir, moov);
      final chapters = await M4bChapterParser.parseChapters(path);
      expect(chapters, isEmpty);
    });
  });
}

/// Minimal `mdhd` payload: version 0, timescale at offset 12.
Uint8List _buildMdhd() {
  final data = ByteData(24);
  data.setUint8(0, 0); // version
  data.setUint32(12, 44100, Endian.big); // timescale
  return data.buffer.asUint8List();
}

/// `stsz` payload: [4]=default sample size, [8]=sample count, [12..]=sizes.
Uint8List _buildStsz(int sampleCount, int defaultSize) {
  final data = ByteData(12);
  data.setUint32(4, defaultSize, Endian.big);
  data.setUint32(8, sampleCount, Endian.big);
  return data.buffer.asUint8List();
}

/// `stts` payload: [4]=entry count, then (count, delta) pairs.
Uint8List _buildStts(int entries, int delta, {int? runCount}) {
  final b = BytesBuilder();
  b.add(Uint8List(8));
  final head = ByteData(4)..setUint32(0, entries, Endian.big);
  b.add(head.buffer.asUint8List());
  final pair = ByteData(8)
    ..setUint32(0, runCount ?? 1, Endian.big)
    ..setUint32(4, delta, Endian.big);
  b.add(pair.buffer.asUint8List());
  return b.toBytes();
}

/// `stco` payload: [4]=chunk count, then 4-byte offsets.
Uint8List _buildChunkTable(int chunks) {
  final b = BytesBuilder();
  b.add(Uint8List(8));
  final head = ByteData(4)..setUint32(0, chunks, Endian.big);
  b.add(head.buffer.asUint8List());
  for (var i = 0; i < chunks; i++) {
    final off = ByteData(4)..setUint32(0, 0, Endian.big);
    b.add(off.buffer.asUint8List());
  }
  return b.toBytes();
}
