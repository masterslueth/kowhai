import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:kowhai/services/scanner_service.dart';

void main() {
  group('ScannerService', () {
    late Directory tempDir;
    late ScannerService scannerService;

    setUp(() async {
      scannerService = ScannerService();
      tempDir = await Directory.systemTemp.createTemp('kowhai_test_');
    });

    tearDown(() async {
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {
        // audio_metadata_reader might leave file handles open on crash
      }
    });

    // ── CUE sheet support ────────────────────────────────────────────────────

    test('single-file .cue: chapters, title, and author are parsed', () async {
      final bookDir = Directory('${tempDir.path}/My Audiobook');
      await bookDir.create();

      await File('${bookDir.path}/audiobook.mp3').writeAsBytes([]);
      await File('${bookDir.path}/audiobook.cue').writeAsString('''
PERFORMER "Some Author"
TITLE "My Audiobook"
FILE "audiobook.mp3" MP3
  TRACK 01 AUDIO
    TITLE "Chapter One"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "Chapter Two"
    INDEX 01 10:30:00
  TRACK 03 AUDIO
    TITLE "Chapter Three"
    INDEX 01 25:15:37
''');

      final books = await scannerService.scanFolder(tempDir.path);
      expect(books.length, 1);
      final book = books.first;

      expect(book.title, 'My Audiobook');
      expect(book.author, 'Some Author');
      expect(book.chapters.length, 3);

      expect(book.chapters[0].title, 'Chapter One');
      expect(book.chapters[0].start, Duration.zero);

      expect(book.chapters[1].title, 'Chapter Two');
      // 10:30:00 → 10*60000 + 30*1000 + 0 = 630 000 ms
      expect(book.chapters[1].start, const Duration(milliseconds: 630000));

      expect(book.chapters[2].title, 'Chapter Three');
      // 25:15:37 → 25*60000 + 15*1000 + 37*1000÷75 = 1 500 000 + 15 000 + 493 = 1 515 493 ms
      expect(book.chapters[2].start, const Duration(milliseconds: 1515493));
    });

    test('multi-file .cue: audio files use cue order, no chapters', () async {
      final bookDir = Directory('${tempDir.path}/Multi Book');
      await bookDir.create();

      // Create files in reverse alphabetical order on disk.
      for (final name in ['part3.mp3', 'part1.mp3', 'part2.mp3']) {
        await File('${bookDir.path}/$name').writeAsBytes([]);
      }

      await File('${bookDir.path}/book.cue').writeAsString('''
PERFORMER "The Author"
TITLE "Multi Book"
FILE "part1.mp3" MP3
  TRACK 01 AUDIO
    TITLE "Part One"
    INDEX 01 00:00:00
FILE "part2.mp3" MP3
  TRACK 02 AUDIO
    TITLE "Part Two"
    INDEX 01 00:00:00
FILE "part3.mp3" MP3
  TRACK 03 AUDIO
    TITLE "Part Three"
    INDEX 01 00:00:00
''');

      final books = await scannerService.scanFolder(tempDir.path);
      expect(books.length, 1);
      final book = books.first;

      // Should follow cue order, not alphabetical.
      expect(book.audioFiles.length, 3);
      expect(book.audioFiles[0], endsWith('part1.mp3'));
      expect(book.audioFiles[1], endsWith('part2.mp3'));
      expect(book.audioFiles[2], endsWith('part3.mp3'));

      // Multi-file cue: no chapter list (each file is an implicit chapter).
      expect(book.chapters, isEmpty);

      expect(book.title, 'Multi Book');
      expect(book.author, 'The Author');
    });

    test('.cue with missing audio file reference is skipped gracefully', () async {
      final bookDir = Directory('${tempDir.path}/Bad Cue Book');
      await bookDir.create();

      // The .cue references a file that does not exist.
      await File('${bookDir.path}/book.cue').writeAsString('''
TITLE "Bad Book"
FILE "missing.mp3" MP3
  TRACK 01 AUDIO
    TITLE "Chapter 1"
    INDEX 01 00:00:00
''');

      // No audio file on disk → scanner should skip the folder.
      final books = await scannerService.scanFolder(tempDir.path);
      expect(books, isEmpty);
    });

    test('.cue FILE directive cannot traverse out of the book folder', () async {
      // A real file OUTSIDE the book folder that a traversal must not reach.
      final outside = File('${tempDir.path}/secret.mp3');
      await outside.writeAsBytes([]);

      final bookDir = Directory('${tempDir.path}/Traversal Book');
      await bookDir.create();
      await File('${bookDir.path}/book.cue').writeAsString('''
TITLE "Traversal Book"
FILE "../secret.mp3" MP3
  TRACK 01 AUDIO
    TITLE "Chapter 1"
    INDEX 01 00:00:00
''');

      final books = await scannerService.scanFolder(tempDir.path);
      // The escaping reference resolves to nothing, so the book has no audio
      // and is dropped rather than exposing an out-of-folder path.
      expect(books, isEmpty);
      for (final b in books) {
        for (final f in b.audioFiles) {
          expect(f, isNot(contains('secret.mp3')));
        }
      }
    });

    test('.cue FILE directive rejects absolute references', () async {
      final target = File('${tempDir.path}/secret.mp3');
      await target.writeAsBytes([]);

      final bookDir = Directory('${tempDir.path}/Absolute Cue Book');
      await bookDir.create();
      final escaped = target.path.replaceAll(r'\', r'\\');
      await File('${bookDir.path}/book.cue').writeAsString('''
TITLE "Absolute Cue Book"
FILE "$escaped" MP3
  TRACK 01 AUDIO
    TITLE "Chapter 1"
    INDEX 01 00:00:00
''');

      final books = await scannerService.scanFolder(tempDir.path);
      for (final b in books) {
        for (final f in b.audioFiles) {
          expect(f, isNot(contains('secret.mp3')));
        }
      }
    });

    test('.cue chapters are sorted ascending by start', () async {
      final bookDir = Directory('${tempDir.path}/Unordered Cue');
      await bookDir.create();
      await File('${bookDir.path}/book.mp3').writeAsBytes([]);

      // Deliberately out of order: chapter 2's INDEX precedes chapter 1's.
      await File('${bookDir.path}/book.cue').writeAsString('''
TITLE "Unordered Cue"
FILE "book.mp3" MP3
  TRACK 01 AUDIO
    TITLE "Chapter One"
    INDEX 01 30:00:00
  TRACK 02 AUDIO
    TITLE "Chapter Two"
    INDEX 01 00:00:00
''');

      final books = await scannerService.scanFolder(tempDir.path);
      expect(books, isNotEmpty);
      final starts = books.first.chapters.map((c) => c.start).toList();
      for (var i = 1; i < starts.length; i++) {
        expect(starts[i], greaterThanOrEqualTo(starts[i - 1]),
            reason: 'chapters must be monotonic for the binary search');
      }
    });

    test('.cue disc TITLE is not used as the first chapter name', () async {
      final bookDir = Directory('${tempDir.path}/Disc Title');
      await bookDir.create();
      await File('${bookDir.path}/book.mp3').writeAsBytes([]);

      // Red Book grammar: the TITLE directly after FILE is the disc title;
      // only a TITLE after a TRACK line names that track.
      await File('${bookDir.path}/book.cue').writeAsString('''
PERFORMER "Author"
TITLE "The Book"
FILE "book.mp3" MP3
  TRACK 01 AUDIO
    TITLE "Real Chapter One"
    INDEX 01 00:00:00
''');

      final books = await scannerService.scanFolder(tempDir.path);
      expect(books, isNotEmpty);
      // Single-file books carry their names on `chapters` (chapterNames is
      // only synthesised for multi-file books).
      final chapterTitles = books.first.chapters.map((c) => c.title).toList();
      expect(chapterTitles, contains('Real Chapter One'));
      expect(chapterTitles, isNot(contains('The Book')));
    });

    test('.cue rejects out-of-range timestamps instead of producing negatives',
        () async {
      final bookDir = Directory('${tempDir.path}/Bad Timestamps');
      await bookDir.create();
      await File('${bookDir.path}/book.mp3').writeAsBytes([]);

      await File('${bookDir.path}/book.cue').writeAsString('''
TITLE "Bad Timestamps"
FILE "book.mp3" MP3
  TRACK 01 AUDIO
    TITLE "Chapter One"
    INDEX 01 00:-5:00
''');

      final books = await scannerService.scanFolder(tempDir.path);
      for (final b in books) {
        for (final c in b.chapters) {
          expect(c.start.isNegative, isFalse);
        }
      }
    });

    test('.cue metadata does not override embedded tags', () async {
      // If a .cue has a title/author but the audio file also provides them
      // via embedded metadata, embedded metadata wins.
      // This test uses a dummy file (metadata read will fail → fall back to
      // folder name), so the .cue title IS used (it's still a fallback).
      final bookDir = Directory('${tempDir.path}/Embedded Wins');
      await bookDir.create();

      await File('${bookDir.path}/audiobook.mp3').writeAsBytes([]);
      await File('${bookDir.path}/audiobook.cue').writeAsString('''
PERFORMER "Cue Author"
TITLE "Cue Title"
FILE "audiobook.mp3" MP3
  TRACK 01 AUDIO
    TITLE "Chapter 1"
    INDEX 01 00:00:00
''');

      final books = await scannerService.scanFolder(tempDir.path);
      expect(books.length, 1);
      // Dummy file has no embedded metadata, so .cue title/author are used.
      expect(books.first.title, 'Cue Title');
      expect(books.first.author, 'Cue Author');
    });

    // ── Chapter name detection ───────────────────────────────────────────────

    test('chapterNames is empty when metadata read fails (dummy files)', () async {
      // Dummy files have no valid metadata — chapterNames should stay empty
      // and the player falls back to filenames.
      final bookDir = Directory('${tempDir.path}/No Meta Book');
      await bookDir.create();
      for (final name in ['01 - Chapter One.mp3', '02 - Chapter Two.mp3']) {
        await File('${bookDir.path}/$name').writeAsBytes([]);
      }

      final books = await scannerService.scanFolder(tempDir.path);
      expect(books.length, 1);
      expect(books.first.chapterNames, isEmpty);
    });

    test('single-file book has empty chapterNames (uses chapters instead)', () async {
      final bookDir = Directory('${tempDir.path}/Single File Book');
      await bookDir.create();
      // .cue makes this a single-file book with chapters
      await File('${bookDir.path}/audiobook.mp3').writeAsBytes([]);
      await File('${bookDir.path}/audiobook.cue').writeAsString('''
TITLE "My Book"
FILE "audiobook.mp3" MP3
  TRACK 01 AUDIO
    TITLE "Chapter 1"
    INDEX 01 00:00:00
''');

      final books = await scannerService.scanFolder(tempDir.path);
      expect(books.length, 1);
      // chapterNames not used for single-file books — chapters list is the source
      expect(books.first.chapterNames, isEmpty);
      expect(books.first.chapters.length, 1);
    });

    // ── Recursion depth ──────────────────────────────────────────────────────

    test('books at depth 3 (root/author/series/book) are found', () async {
      // root / Author / Series / Book
      final bookDir = Directory('${tempDir.path}/Author/Series/Book');
      await bookDir.create(recursive: true);
      await File('${bookDir.path}/chapter.mp3').writeAsBytes([]);

      final books = await scannerService.scanFolder(tempDir.path);
      expect(books.length, 1);
      expect(books.first.title, 'Book');
    });

    test('books deeper than maxScanDepth (depth 4) are not found', () async {
      // root / A / B / C / Book — one level too deep
      final bookDir = Directory('${tempDir.path}/A/B/C/Book');
      await bookDir.create(recursive: true);
      await File('${bookDir.path}/chapter.mp3').writeAsBytes([]);

      final books = await scannerService.scanFolder(tempDir.path);
      expect(books, isEmpty);
    });

    // ── Natural sort ─────────────────────────────────────────────────────────

    test('naturalSort orders files correctly (e.g. 2.mp3 before 10.mp3)', () async {
      // Create a dummy audiobook folder
      final bookDir = Directory('${tempDir.path}/Test Book');
      await bookDir.create();

      // Create files in an arbitrary order to see if the scanner sorts them naturally
      final files = [
        '10 - Chapter.mp3',
        '2 - Chapter.mp3',
        '1 - Chapter.mp3',
        '20 - Chapter.mp3',
        'something_else.mp3',
      ];

      for (final name in files) {
        final f = File('${bookDir.path}/$name');
        await f.writeAsString('dummy mp3 content');
      }

      // Scan
      final books = await scannerService.scanFolder(tempDir.path);

      expect(books.length, 1);
      final book = books.first;
      
      // Expected natural order: 1, 2, 10, 20, something_else
      expect(book.audioFiles.length, 5);
      expect(book.audioFiles[0].endsWith('1 - Chapter.mp3'), true);
      expect(book.audioFiles[1].endsWith('2 - Chapter.mp3'), true);
      expect(book.audioFiles[2].endsWith('10 - Chapter.mp3'), true);
      expect(book.audioFiles[3].endsWith('20 - Chapter.mp3'), true);
      expect(book.audioFiles[4].endsWith('something_else.mp3'), true);
    });
  });
}
