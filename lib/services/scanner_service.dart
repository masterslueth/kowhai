import 'dart:io';
import 'dart:isolate';
import 'package:audio_metadata_reader/audio_metadata_reader.dart'
    hide Chapter;
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../models/audiobook.dart';
import '../utils/cover_picker.dart';
import '../utils/natural_sort.dart';
import 'm4b_chapter_parser.dart';
import 'opf_parser.dart';

/// Parsed result from a `.cue` sheet file.
class _CueSheet {
  final String? title;
  final String? author;

  /// Resolved, on-disk audio file paths in cue-sheet order.
  final List<String> audioFiles;

  /// Chapter list — only populated for single-file cue sheets.
  /// Multi-file cue sheets leave this empty (each file is its own chapter).
  final List<Chapter> chapters;

  const _CueSheet({
    this.title,
    this.author,
    required this.audioFiles,
    required this.chapters,
  });
}

class ScannerService {
  static const _audioExtensions = {'.mp3', '.m4a', '.aac', '.m4b', '.flac', '.ogg'};
  static const _imageExtensions = {'.jpg', '.jpeg', '.png', '.webp'};
  // Audible formats — detected but not playable due to DRM.
  static const _drmExtensions = {'.aax', '.aa'};

  /// Maximum folder depth below the library root that the scanner descends
  /// into when looking for audiobooks.
  ///
  /// Depth is counted from (but not including) the library root:
  /// `root/author/series/book` is depth 3. Supports three common layouts —
  /// flat (`root/book`), author-grouped (`root/author/book`), and
  /// author+series (`root/author/series/book`).
  static const int maxScanDepth = 3;

  static void _log(String msg) => debugPrint('[Kowhai:Scanner] $msg');

  Future<List<Audiobook>> scanFolder(String folderPath,
      {Set<String> excludePaths = const {},
      void Function(Audiobook)? onBookFound}) async {
    final dir = Directory(folderPath);
    _log('── SCAN START ──────────────────────────────');
    _log('Root path : $folderPath');
    _log('Exists    : ${await dir.exists()}');

    if (!await dir.exists()) {
      _log('Root does not exist — aborting.');
      return [];
    }

    // Unlike subfolder listings (which degrade to "skip this folder"), a root
    // listing failure is fatal to the scan — rethrow so callers surface a
    // friendly retryable error (see friendlyScanError) instead of silently
    // presenting an empty library.
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list().toList();
    } catch (e) {
      _log('ERROR listing root: $e');
      rethrow;
    }
    final subdirs = entries
        .whereType<Directory>()
        .where((d) =>
            !p.basename(d.path).startsWith('.') &&
            !excludePaths.contains(d.path))
        .toList();
    final rootFiles = entries
        .whereType<File>()
        .where((f) => !p.basename(f.path).startsWith('.'))
        .toList();

    _log('Entries   : ${entries.length} total '
        '(${subdirs.length} dirs, ${rootFiles.length} files)');
    _log('Subdirs   : ${subdirs.map((d) => p.basename(d.path)).join(', ')}');

    final books = <Audiobook>[];
    for (final subdir in subdirs) {
      final results = await _scanAsBookOrAuthorFolder(subdir);
      for (final book in results) {
        onBookFound?.call(book);
      }
      books.addAll(results);
    }

    books.sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    _log('── SCAN END — ${books.length} book(s) found ──');
    return books;
  }

  /// Scans [bookDir] as a single audiobook directory. Used by Drive integration
  /// to re-scan a downloaded book and get full metadata.
  Future<Audiobook?> scanSingleBook(String bookDirPath) =>
      _scanSubfolder(Directory(bookDirPath));

  /// Tries to scan [dir] as a single book. If that fails (no audio files
  /// directly inside), treats it as an author/grouping folder and recurses into
  /// its subdirectories — up to [remainingDepth] extra levels deep.
  ///
  /// Default of `maxScanDepth - 1` accounts for [dir] itself already being
  /// one level below root.
  Future<List<Audiobook>> _scanAsBookOrAuthorFolder(Directory dir,
      {int remainingDepth = maxScanDepth - 1}) async {
    final book = await _scanSubfolder(dir);
    if (book != null) return [book];

    if (remainingDepth <= 0) return const [];

    // No audio files directly in dir — check whether it has subdirectories
    // that might be individual books (author/series folder pattern).
    List<FileSystemEntity> entries;
    try {
      entries = await dir.list().toList();
    } catch (e) {
      return const [];
    }
    final subdirs = entries
        .whereType<Directory>()
        .where((d) => !p.basename(d.path).startsWith('.'))
        .toList();
    if (subdirs.isEmpty) return const [];

    _log('  "${p.basename(dir.path)}" has no audio — treating as grouping folder '
        '(${subdirs.length} sub-folder(s), depth remaining: $remainingDepth)');
    final books = <Audiobook>[];
    for (final sub in subdirs) {
      final results = await _scanAsBookOrAuthorFolder(sub,
          remainingDepth: remainingDepth - 1);
      books.addAll(results);
    }
    return books;
  }

  Future<Audiobook?> _scanSubfolder(Directory dir) async {
    final name = p.basename(dir.path);
    _log('  Folder: "$name"');

    List<FileSystemEntity> entries;
    try {
      entries = await dir.list().toList();
    } catch (e) {
      _log('    ERROR listing folder: $e');
      return null;
    }

    final allFiles = entries
        .whereType<File>()
        .where((f) => !p.basename(f.path).startsWith('.'))
        .toList();
    final audioFiles = allFiles
        .where((f) => _isAudio(f.path))
        .map((f) => f.path)
        .toList()
      ..sort(_naturalSort);

    final imageFiles = allFiles.where((f) => _isImage(f.path)).toList();

    // Parse .cue sheet if one exists (takes precedence over natural-sort order).
    _CueSheet? cueSheet;
    final cueFiles = allFiles
        .where((f) => p.extension(f.path).toLowerCase() == '.cue')
        .toList();
    if (cueFiles.isNotEmpty) {
      try {
        final content = await cueFiles.first.readAsString();
        cueSheet = _parseCueSheet(content, dir.path);
        _log('    CUE: ${cueSheet?.audioFiles.length ?? 0} file(s), '
            '${cueSheet?.chapters.length ?? 0} chapter(s)');
      } catch (e) {
        _log('    CUE parse error: $e');
      }
    }

    // If the .cue sheet resolved audio files, use that ordered list; otherwise
    // fall back to the naturally-sorted files found on disk.
    if (cueSheet != null && cueSheet.audioFiles.isNotEmpty) {
      audioFiles
        ..clear()
        ..addAll(cueSheet.audioFiles);
    }

    _log('    Audio (${audioFiles.length}): ${audioFiles.map(p.basename).join(', ')}');
    _log('    Images(${imageFiles.length}): ${imageFiles.map((f) => p.basename(f.path)).join(', ')}');

    if (audioFiles.isEmpty) {
      // Check for DRM-locked Audible files before skipping.
      final drmFiles = allFiles.where((f) => _isDrm(f.path)).toList();
      if (drmFiles.isNotEmpty) {
        // Use the filename (minus extension) as title when there is only one
        // file; otherwise fall back to the folder name.
        final title = drmFiles.length == 1
            ? p.basenameWithoutExtension(drmFiles.first.path)
            : name;
        _log('    → DRM-LOCKED (${drmFiles.length} file(s): '
            '${drmFiles.map((f) => p.basename(f.path)).join(', ')})');
        return Audiobook(
          title: title,
          path: dir.path,
          audioFiles: const [],
          isDrmLocked: true,
        );
      }
      _log('    → SKIP (no recognised audio files)');
      return null;
    }

    final coverPath = _pickBestCover(imageFiles);
    String title = name;
    String? author;
    String? narrator;
    Duration totalDuration = Duration.zero;
    final chapterDurations = <Duration>[];
    final rawTitles = <String?>[];
    Uint8List? coverBytes;
    bool foundCoverInMetadata = false;

    // Check for metadata.opf (case-insensitive) and parse it first.
    // OPF values will override audio-tag values for the mapped fields.
    OpfMetadata opf = const OpfMetadata();
    final opfFile = allFiles.where((f) =>
        p.basename(f.path).toLowerCase() == 'metadata.opf').firstOrNull;
    if (opfFile != null) {
      try {
        opf = parseOpf(await opfFile.readAsString());
        _log('    OPF: found (author=${opf.author}, narrator=${opf.narrator}, '
            'series=${opf.series})');
      } catch (e) {
        _log('    OPF parse error: $e');
      }
    }

    // Read metadata from each audio file in BACKGROUND-ISOLATE CHUNKS so
    // large libraries don't jank the UI thread. Chunking (rather than one
    // monolithic Isolate.run) lets the event loop breathe between batches so
    // live scan-phase labels keep flowing. Per-file errors are contained
    // inside the worker and surface as zero-duration entries, exactly like
    // the previous inline try/catch behaviour.
    //
    // - Duration is always summed across all files.
    // - Title/author are taken from the first file that has them.
    // - Embedded art is taken from the first file that has it (only sought
    //   when no image file exists on disk), capped at _maxEmbeddedArtBytes
    //   because bytes cross isolate boundaries by copy.
    const metadataChunkSize = 20;
    for (var i = 0; i < audioFiles.length; i += metadataChunkSize) {
      final chunk = audioFiles
          .sublist(i, (i + metadataChunkSize).clamp(0, audioFiles.length));
      final wantArt = coverPath == null && !foundCoverInMetadata;
      final metas =
          await Isolate.run(() => readMetadataChunk(chunk, wantArt: wantArt));

      for (var j = 0; j < metas.length; j++) {
        final meta = metas[j];
        final fileName = p.basename(audioFiles[i + j]);

        if (meta.error != null) {
          _log('    Metadata error for $fileName: ${meta.error}');
        }

        // Sum durations.
        chapterDurations.add(meta.duration);
        totalDuration += meta.duration;

        // Collect raw track title for chapter name detection later.
        rawTitles.add(meta.title);

        // Use album tag as book title (track title is a chapter name, not the book).
        if (title == name) {
          final album = meta.album;
          if (album != null && album.isNotEmpty) title = album;
        }

        // Use first non-empty artist as author; fall back to performers list.
        // OPF author takes precedence - only read from tags if OPF had none.
        if (author == null && opf.author == null) {
          final a = meta.artist;
          if (a != null && a.isNotEmpty) {
            author = a;
          } else if (meta.firstPerformer != null) {
            author = meta.firstPerformer;
          }
        }

        // Extract embedded cover art.
        if (!foundCoverInMetadata && meta.art != null) {
          coverBytes = meta.art;
          foundCoverInMetadata = true;
          _log('    Embedded art found in $fileName: '
              '${coverBytes!.length} bytes');
        }
      }
    }

    // .cue metadata fills in what embedded tags didn't provide.
    if (cueSheet?.title != null && title == name) title = cueSheet!.title!;
    if (cueSheet?.author != null && author == null) author = cueSheet!.author;

    // OPF metadata wins over audio tags and .cue for all mapped fields.
    if (opf.title != null) title = opf.title!;
    if (opf.author != null) author = opf.author;
    if (opf.narrator != null) narrator = opf.narrator;

    // Extract extended metadata (narrator, description, publisher, language,
    // release date) from the first audio file using format-specific tags.
    // OPF values take precedence — only read from audio tags for fields
    // that OPF didn't provide.
    String? description = opf.description;
    String? publisher = opf.publisher;
    String? language = opf.language;
    String? releaseDate = opf.releaseDate;
    final String? series = opf.series;
    final int? seriesIndex = opf.seriesIndex;
    if (audioFiles.isNotEmpty) {
      try {
        final raw = readAllMetadata(File(audioFiles.first), getImage: false);
        if (raw is Mp3Metadata) {
          final lp = raw.leadPerformer?.trim();
          if (lp != null && lp.isNotEmpty && lp != author && narrator == null) narrator = lp;
          final commentText = raw.comments.firstOrNull?.text.trim();
          if (commentText != null && commentText.isNotEmpty && description == null) {
            description = commentText;
          }
          final pub = raw.publisher?.trim();
          if (pub != null && pub.isNotEmpty && publisher == null) publisher = pub;
          final lang = raw.languages?.trim();
          if (lang != null && lang.isNotEmpty && language == null) language = lang;
          if (raw.year != null && raw.year! > 0 && releaseDate == null) {
            releaseDate = raw.year.toString();
          }
        } else if (raw is VorbisMetadata) {
          final perf = raw.performer.firstOrNull?.trim();
          if (perf != null && perf.isNotEmpty && narrator == null) narrator = perf;
          final desc = raw.description.firstOrNull?.trim() ??
              raw.comment.firstOrNull?.trim();
          if (desc != null && desc.isNotEmpty && description == null) description = desc;
          final org = raw.organization.firstOrNull?.trim();
          if (org != null && org.isNotEmpty && publisher == null) publisher = org;
          final yr = raw.date.firstOrNull?.year;
          if (yr != null && yr > 0 && releaseDate == null) releaseDate = yr.toString();
        } else if (raw is Mp4Metadata) {
          final yr = raw.year?.year;
          if (yr != null && yr > 0 && releaseDate == null) releaseDate = yr.toString();
        }
      } catch (e) {
        _log('    Extended metadata error: $e');
      }
    }

    // Build per-file chapter names for multi-file books from title metadata.
    // M4B and single-file CUE books use the chapters list instead.
    List<String> chapterNames = const [];
    if (audioFiles.length > 1) {
      final names = [
        for (int i = 0; i < audioFiles.length; i++)
          _detectChapterName(
            rawTitles.length > i ? rawTitles[i] : null,
            title,
            audioFiles[i],
          ),
      ];
      // Only store if at least one name differs from the filename fallback,
      // i.e. metadata actually improved on the bare filename.
      final anyImproved = names.indexed.any((e) =>
          e.$2 != p.basenameWithoutExtension(audioFiles[e.$1]));
      if (anyImproved) chapterNames = names;
    }

    // Chapter parsing: embedded M4B takes priority; .cue is second choice.
    List<Chapter> chapters = const [];
    if (audioFiles.length == 1 &&
        p.extension(audioFiles.first).toLowerCase() == '.m4b') {
      chapters = await M4bChapterParser.parseChapters(audioFiles.first);
      _log('    M4B chapters: ${chapters.length}');
    } else if (cueSheet != null && cueSheet.chapters.isNotEmpty) {
      // Sorted ascending: Audiobook.chapterIndexAt binary-searches on
      // Chapter.start assuming both parsers emit monotonic chapters. A
      // hand-authored cue with out-of-order INDEX lines must not break that.
      chapters = List.of(cueSheet.chapters)
        ..sort((a, b) => a.start.compareTo(b.start));
      _log('    CUE chapters: ${chapters.length}');
    }

    final duration = totalDuration == Duration.zero ? null : totalDuration;
    _log('    title="$title" author="${author ?? 'none'}" '
        'duration=${duration?.toString() ?? 'unknown'} '
        'cover=${coverPath != null ? p.basename(coverPath) : coverBytes != null ? '<embedded>' : 'none'}');
    _log('    → HIT');

    return Audiobook(
      title: title,
      author: author,
      duration: duration,
      path: dir.path,
      coverImagePath: coverPath,
      coverImageBytes: coverBytes,
      audioFiles: audioFiles,
      chapterDurations: chapterDurations,
      chapters: chapters,
      chapterNames: chapterNames,
      narrator: narrator,
      description: description,
      publisher: publisher,
      language: language,
      releaseDate: releaseDate,
      series: series,
      seriesIndex: seriesIndex,
    );
  }

  /// Cover priority:
  ///   1. cover.jpg or Cover.jpg (exact filename)
  ///   2. Any image whose base name contains "cover" (case-insensitive)
  ///   3. First image found
  String? _pickBestCover(List<File> images) {
    final best = pickBestCover(images, (f) => p.basename(f.path));
    return best?.path;
  }

  /// Natural sort: compares strings by splitting into numeric and non-numeric
  /// segments so that "2.mp3" < "10.mp3" < "100.mp3".
  int _naturalSort(String a, String b) {
    final nameA = p.basename(a);
    final nameB = p.basename(b);
    return naturalCompare(nameA, nameB);
  }

  // ── Chapter name detection ───────────────────────────────────────────────

  /// Derives a display chapter name from [title] (the ID3/Vorbis title tag),
  /// [album] (the book title), and [filePath] as a final fallback.
  ///
  /// Heuristic:
  ///   1. Empty/null title → filename without extension
  ///   2. Title equals album (tagger copied album→title) → filename
  ///   3. Title contains " - " or " | " → extract part after last delimiter
  ///   4. Otherwise → use title directly
  String _detectChapterName(String? title, String album, String filePath) {
    if (title == null || title.isEmpty) {
      return p.basenameWithoutExtension(filePath);
    }

    if (title.toLowerCase() == album.toLowerCase()) {
      return p.basenameWithoutExtension(filePath);
    }

    for (final delimiter in [' - ', ' | ']) {
      final idx = title.lastIndexOf(delimiter);
      if (idx > 0) {
        final after = title.substring(idx + delimiter.length).trim();
        if (after.isNotEmpty) return after;
      }
    }

    return title;
  }

  // ── CUE sheet parser ─────────────────────────────────────────────────────
  //
  // Parses a Red Book / CD-DA cue sheet into a [_CueSheet].
  //
  // Supported subset:
  //   FILE "name" <type>   – audio file reference (quoted or unquoted)
  //   PERFORMER "..."      – global author (ignored at track level)
  //   TITLE "..."          – global title or per-track chapter name
  //   TRACK nn AUDIO       – track declaration
  //   INDEX 01 MM:SS:FF    – chapter start (75 frames/sec)
  //
  // Multi-file cue sheets (more than one FILE directive) are supported for
  // ordering and metadata, but chapters are only extracted for single-file
  // sheets because track timestamps are relative to each file's start.

  _CueSheet? _parseCueSheet(String content, String folderPath) {
    String? globalTitle;
    String? globalPerformer;

    // Accumulate per-FILE sections.
    final fileSections = <({String path, List<Chapter> chapters})>[];
    String? currentFilePath; // null if file was missing from disk
    final pendingChapters = <Chapter>[];
    String? pendingTrackTitle;
    // Disc/album title seen in the current FILE section before any TRACK;
    // the first one is retained as a book-title fallback.
    var sawTrackInSection = false;
    String? firstSectionTitle;

    void commitFile() {
      if (currentFilePath != null) {
        fileSections.add((
          path: currentFilePath!,
          chapters: List.of(pendingChapters),
        ));
      }
      pendingChapters.clear();
      currentFilePath = null;
      pendingTrackTitle = null;
      sawTrackInSection = false;
    }

    for (var line in content.split('\n')) {
      line = line.trim();
      if (line.isEmpty || line.startsWith('REM')) continue;

      if (line.startsWith('FILE ')) {
        commitFile();
        final match = RegExp(r'^FILE\s+"(.+?)"\s+\S+').firstMatch(line) ??
            RegExp(r'^FILE\s+(\S+)\s+\S+').firstMatch(line);
        if (match == null) continue;
        // Normalise path separators for the current platform.
        final filename = match.group(1)!.replaceAll('\\', p.separator);
        currentFilePath = _resolveCueFile(folderPath, filename);
        pendingTrackTitle = null;
      } else if (line.startsWith('TITLE ')) {
        final title = _cueUnquote(line.substring(6));
        // Red Book cue grammar: the FIRST TITLE inside a FILE section is the
        // disc/album title; any TITLE that follows a TRACK line is that
        // track's name. Without the TRACK gate, chapter 1 inherited the book
        // title instead of its own name.
        if (currentFilePath == null && fileSections.isEmpty) {
          globalTitle = title;
        } else if (!sawTrackInSection) {
          firstSectionTitle ??= title;
        } else {
          pendingTrackTitle = title;
        }
      } else if (line.startsWith('PERFORMER ')) {
        final performer = _cueUnquote(line.substring(10));
        if (currentFilePath == null && fileSections.isEmpty) {
          globalPerformer = performer;
        }
      } else if (line.startsWith('TRACK ') || line.startsWith('TRACK\t')) {
        sawTrackInSection = true;
      } else if (line.startsWith('INDEX 01 ') && pendingTrackTitle != null) {
        final dur = _parseCueTime(line.substring(9).trim());
        if (dur != null && currentFilePath != null) {
          pendingChapters.add(Chapter(title: pendingTrackTitle!, start: dur));
        }
        pendingTrackTitle = null; // consumed
      }
    }
    commitFile();

    if (fileSections.isEmpty) return null;

    final audioPaths = fileSections.map((s) => s.path).toList();

    // Only expose chapters for single-file sheets; multi-file track timestamps
    // are relative to their respective file — not yet supported.
    final chapters = fileSections.length == 1
        ? fileSections.first.chapters
        : const <Chapter>[];

    return _CueSheet(
      // Some sheets carry no global TITLE but do declare a per-FILE disc
      // title; fall back to it rather than dropping the metadata entirely.
      title: globalTitle ?? firstSectionTitle,
      author: globalPerformer,
      audioFiles: audioPaths,
      chapters: chapters,
    );
  }

  /// Strips surrounding quotes from a cue-sheet string value.
  String _cueUnquote(String s) {
    s = s.trim();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      return s.substring(1, s.length - 1);
    }
    return s;
  }

  /// Resolves a cue `FILE` reference to an existing path INSIDE [root].
  ///
  /// The reference is read from file *contents*, so it is untrusted input.
  /// `p.join` normalises `..` segments, so a crafted cue sheet such as
  /// `FILE "../../../../data/data/com.app/files/secret.mp3" WAVE` would
  /// otherwise walk out of the book folder and hand an arbitrary absolute path
  /// to the metadata reader and the playback engine. Absolute references are
  /// rejected outright, and the normalised candidate must still resolve under
  /// [root]. Returns null when the reference escapes or the file is absent.
  String? _resolveCueFile(String root, String filename) {
    if (p.isAbsolute(filename)) return null;
    final normalizedRoot = p.normalize(p.absolute(root));
    final candidate = p.normalize(p.absolute(p.join(root, filename)));
    // p.relative emits '..' segments exactly when the candidate escapes root.
    final rel = p.relative(candidate, from: normalizedRoot);
    if (rel == '..' || rel.startsWith('..${p.separator}')) return null;
    return File(candidate).existsSync() ? candidate : null;
  }

  /// Parses a CUE timestamp `MM:SS:FF` (75 frames/sec) to [Duration].
  ///
  /// Each field is range-checked. `int.tryParse` happily accepts a leading
  /// `-`, and a negative `Chapter.start` breaks the ascending-order
  /// precondition that [Audiobook.chapterIndexAt]'s binary search relies on.
  Duration? _parseCueTime(String s) {
    final parts = s.split(':');
    if (parts.length != 3) return null;
    final mm = int.tryParse(parts[0]);
    final ss = int.tryParse(parts[1]);
    final ff = int.tryParse(parts[2]);
    if (mm == null || ss == null || ff == null) return null;
    if (mm < 0 || ss < 0 || ff < 0) return null;
    if (ss > 59 || ff > 74) return null;
    return Duration(milliseconds: mm * 60000 + ss * 1000 + ff * 1000 ~/ 75);
  }

  bool _isAudio(String path) => _audioExtensions.contains(p.extension(path).toLowerCase());
  bool _isImage(String path) => _imageExtensions.contains(p.extension(path).toLowerCase());
  bool _isDrm(String path) => _drmExtensions.contains(p.extension(path).toLowerCase());
}

// ── Background-isolate metadata worker ──────────────────────────────────────

/// Cap on embedded artwork bytes extracted per file. Art crosses isolate
/// boundaries by copy; unbounded covers spike memory on low-end devices.
const int _maxEmbeddedArtBytes = 4 * 1024 * 1024;

/// Per-file metadata extracted by [readMetadataChunk] inside a background
/// isolate. Mirrors the subset of AudioMetadata the scanner consumes.
typedef FileMetadata = ({
  Duration duration,
  String? title,
  String? album,
  String? artist,
  String? firstPerformer,
  Uint8List? art,

  /// Non-null when reading this file failed - mirrors the previous inline
  /// catch behaviour where a bad file yields a zero-duration entry.
  String? error,
});

/// Reads audio metadata for [paths] in one batch. Top-level function so it
/// can be invoked via [Isolate.run]. Never throws: per-file failures are
/// reported through [FileMetadata.error] and produce zero-duration entries.
List<FileMetadata> readMetadataChunk(
  List<String> paths, {
  required bool wantArt,
}) {
  final out = <FileMetadata>[];
  var seekArt = wantArt;
  for (final path in paths) {
    try {
      final m = readMetadata(File(path), getImage: seekArt);
      Uint8List? art;
      if (seekArt && m.pictures.isNotEmpty) {
        final bytes = m.pictures.first.bytes;
        if (bytes.length <= _maxEmbeddedArtBytes) {
          art = bytes;
          seekArt = false; // first found wins, same as the inline original
        }
      }
      out.add((
        duration: m.duration ?? Duration.zero,
        title: m.title?.trim().isEmpty == true ? null : m.title?.trim(),
        album: m.album,
        artist: m.artist,
        firstPerformer: m.performers.isNotEmpty ? m.performers.first : null,
        art: art,
        error: null,
      ));
    } catch (e) {
      out.add((
        duration: Duration.zero,
        title: null,
        album: null,
        artist: null,
        firstPerformer: null,
        art: null,
        error: e.toString(),
      ));
    }
  }
  return out;
}
