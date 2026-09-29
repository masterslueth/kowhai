import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:kowhai/models/audiobook.dart';
import 'package:kowhai/services/drive_book_repository.dart';
import 'package:kowhai/services/drive_download_manager.dart';
import 'package:kowhai/services/download_progress_tracker.dart';
import 'package:kowhai/services/drive_library_service.dart';
import 'package:kowhai/services/drive_service.dart';
import 'package:kowhai/services/position_service.dart';
import 'package:kowhai/services/preferences_service.dart';
import 'package:kowhai/services/scanner_service.dart';

// Stub scanner that skips actual file parsing — avoids Windows file-handle
// retention that would prevent tearDown from deleting the temp directory.
class _NullScanner extends ScannerService {
  @override
  Future<Audiobook?> scanSingleBook(String dir) async => null;
}

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

class _StubPrefs extends PreferencesService {
  final String? libraryPath;
  _StubPrefs({this.libraryPath});

  @override
  Future<String?> getLibraryPath() async => libraryPath;
}

/// Stand-in path provider so stagingDir resolves to a known temp path.
class _MockPathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String docsPath;
  _MockPathProvider(this.docsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;
}

// ---------------------------------------------------------------------------
// DB bootstrap
// ---------------------------------------------------------------------------

Future<({PositionService positionService, DriveBookRepository repo})>
    _makeRepo() async {
  final db = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 3,
      singleInstance: false,
      onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE positions (
            book_path TEXT PRIMARY KEY,
            chapter_index INTEGER NOT NULL DEFAULT 0,
            position_ms INTEGER NOT NULL DEFAULT 0,
            global_position_ms INTEGER NOT NULL DEFAULT 0,
            total_duration_ms INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL,
            status TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE drive_books (
            folder_id       TEXT PRIMARY KEY,
            folder_name     TEXT NOT NULL,
            root_folder_id  TEXT NOT NULL,
            is_shared       INTEGER NOT NULL DEFAULT 0,
            account_email   TEXT NOT NULL,
            added_at        INTEGER NOT NULL,
            cover_file_id   TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE drive_book_files (
            folder_id       TEXT NOT NULL,
            file_index      INTEGER NOT NULL,
            file_id         TEXT NOT NULL,
            file_name       TEXT NOT NULL,
            mime_type       TEXT NOT NULL,
            size_bytes      INTEGER NOT NULL DEFAULT 0,
            download_state  TEXT NOT NULL DEFAULT 'none',
            local_path      TEXT,
            PRIMARY KEY (folder_id, file_index)
          )
        ''');
      },
    ),
  );
  final ps = PositionService.withDatabase(db);
  return (positionService: ps, repo: DriveBookRepository(ps));
}

DriveLibraryService _makeService(
    DriveBookRepository repo, _StubPrefs prefs) {
  final tracker =
      DownloadProgressTracker(repository: repo, manager: DriveDownloadManager(repo, DriveService()));
  return DriveLibraryService(
    repo,
    DriveService(),
    DriveDownloadManager(repo, DriveService()),
    prefs,
    _NullScanner(),
    tracker,
  );
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

DriveBookRecord _bookRecord(String folderId, String folderName) =>
    DriveBookRecord(
      folderId: folderId,
      folderName: folderName,
      rootFolderId: 'root',
      isShared: false,
      accountEmail: 'user@example.com',
      addedAt: 1000,
      audioFileIds: [],
    );

DriveFileRecord _fileRecord(
  String folderId,
  int index,
  String fileName, {
  DriveDownloadState state = DriveDownloadState.none,
  String? localPath,
}) =>
    DriveFileRecord(
      folderId: folderId,
      fileIndex: index,
      fileId: '$folderId-file$index',
      fileName: fileName,
      mimeType: 'audio/mpeg',
      sizeBytes: 1024,
      downloadState: state,
      localPath: localPath,
    );

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('staging path', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('av_test_');
      PathProviderPlatform.instance = _MockPathProvider(tempDir.path);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('stagingDir always resolves to app storage regardless of library path',
        () async {
      final (:positionService, :repo) = await _makeRepo();
      final prefs = _StubPrefs(libraryPath: '/my/library');
      final service = _makeService(repo, prefs);

      final dir = await service.stagingDir('folder1');
      expect(dir, contains('drive_books/folder1'));
      expect(dir, isNot(contains('/my/library')));
    });

    test('bookDir returns library folder when library path is set', () async {
      final (:positionService, :repo) = await _makeRepo();
      final prefs = _StubPrefs(libraryPath: '/my/library');
      final service = _makeService(repo, prefs);

      final dir = await service.bookDir('folder1', folderName: 'My Book');
      expect(dir, '/my/library/My Book');
    });

    test('bookDir falls back to staging when no library path is set', () async {
      final (:positionService, :repo) = await _makeRepo();
      final prefs = _StubPrefs(libraryPath: null);
      final service = _makeService(repo, prefs);

      final staging = await service.stagingDir('folder1');
      final dir = await service.bookDir('folder1', folderName: 'My Book');
      expect(dir, staging);
    });
  });

  group('promoteToLocal file move', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('av_promote_');
      PathProviderPlatform.instance = _MockPathProvider(tempDir.path);
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('moves downloaded files from staging to library folder', () async {
      final (:positionService, :repo) = await _makeRepo();
      const folderId = 'folder1';
      const folderName = 'My Book';
      final libDir = await Directory('${tempDir.path}/lib').create();

      await repo.upsertDriveBook(_bookRecord(folderId, folderName));

      // Simulate files already downloaded to staging
      final stagingPath =
          '${tempDir.path}/drive_books/$folderId';
      await Directory(stagingPath).create(recursive: true);
      final trackFile = File('$stagingPath/track00.mp3');
      await trackFile.writeAsBytes([1, 2, 3]);

      await repo.upsertFile(_fileRecord(folderId, 0, 'track00.mp3',
          state: DriveDownloadState.done,
          localPath: trackFile.path));

      final prefs = _StubPrefs(libraryPath: libDir.path);
      final service = _makeService(repo, prefs);

      await service.promoteToLocal(folderId);

      // File must now exist in library folder
      expect(
          File('${libDir.path}/$folderName/track00.mp3').existsSync(), isTrue);
      // File must be removed from staging
      expect(trackFile.existsSync(), isFalse);
    });

    test('updates DB localPath after move', () async {
      final (:positionService, :repo) = await _makeRepo();
      const folderId = 'folder2';
      const folderName = 'Move Book';
      final libDir = await Directory('${tempDir.path}/lib2').create();

      await repo.upsertDriveBook(_bookRecord(folderId, folderName));

      final stagingPath = '${tempDir.path}/drive_books/$folderId';
      await Directory(stagingPath).create(recursive: true);
      final trackFile = File('$stagingPath/chapter.mp3');
      await trackFile.writeAsBytes([0]);

      await repo.upsertFile(_fileRecord(folderId, 0, 'chapter.mp3',
          state: DriveDownloadState.done,
          localPath: trackFile.path));

      final prefs = _StubPrefs(libraryPath: libDir.path);
      final service = _makeService(repo, prefs);

      await service.promoteToLocal(folderId);

      final files = await repo.getFilesForBook(folderId);
      expect(files[0].localPath,
          '${libDir.path}/$folderName/chapter.mp3');
    });

    test('staging file is removed after the move (no duplicate left)', () async {
      final (:positionService, :repo) = await _makeRepo();
      const folderId = 'folderMoveCleanup';
      const folderName = 'Cleanup Book';
      final libDir = await Directory('${tempDir.path}/libCleanup').create();

      await repo.upsertDriveBook(_bookRecord(folderId, folderName));

      final stagingPath = '${tempDir.path}/drive_books/$folderId';
      await Directory(stagingPath).create(recursive: true);
      final trackFile = File('$stagingPath/chapter.mp3');
      await trackFile.writeAsBytes([0]);

      await repo.upsertFile(_fileRecord(folderId, 0, 'chapter.mp3',
          state: DriveDownloadState.done, localPath: trackFile.path));

      final service = _makeService(repo, _StubPrefs(libraryPath: libDir.path));
      await service.promoteToLocal(folderId);

      final dest = File('${libDir.path}/$folderName/chapter.mp3');
      expect(dest.existsSync(), isTrue,
          reason: 'destination must exist after promote');
      expect(trackFile.existsSync(), isFalse,
          reason: 'staging copy should be cleaned up after the move');
    });

    test('self-heals a DB row stranded on a deleted staging path', () async {
      // Regression: the old copy→delete→update order could be interrupted
      // between the delete and the update, leaving localPath pointing at a
      // file that no longer existed and the book permanently unplayable.
      final (:positionService, :repo) = await _makeRepo();
      const folderId = 'folderStranded';
      const folderName = 'Stranded Book';
      final libDir = await Directory('${tempDir.path}/libStranded').create();

      await repo.upsertDriveBook(_bookRecord(folderId, folderName));

      // Destination already holds the real file; the staging path is gone.
      final destDir = Directory('${libDir.path}/$folderName');
      await destDir.create(recursive: true);
      await File('${destDir.path}/chapter.mp3').writeAsBytes([0]);

      final stagingPath = '${tempDir.path}/drive_books/$folderId';
      await repo.upsertFile(_fileRecord(folderId, 0, 'chapter.mp3',
          state: DriveDownloadState.done, localPath: '$stagingPath/chapter.mp3'));

      final service = _makeService(repo, _StubPrefs(libraryPath: libDir.path));
      await service.promoteToLocal(folderId);

      final files = await repo.getFilesForBook(folderId);
      expect(files[0].localPath, '${destDir.path}/chapter.mp3',
          reason: 'DB should be repointed at the existing destination');
    });

    test('skips move when no library folder is configured (staging == final)',
        () async {
      final (:positionService, :repo) = await _makeRepo();
      const folderId = 'folder3';
      const folderName = 'No Move Book';

      await repo.upsertDriveBook(_bookRecord(folderId, folderName));

      final stagingPath = '${tempDir.path}/drive_books/$folderId';
      await Directory(stagingPath).create(recursive: true);
      final trackFile = File('$stagingPath/track.mp3');
      await trackFile.writeAsBytes([1]);

      await repo.upsertFile(_fileRecord(folderId, 0, 'track.mp3',
          state: DriveDownloadState.done,
          localPath: trackFile.path));

      final prefs = _StubPrefs(libraryPath: null);
      final service = _makeService(repo, prefs);

      await service.promoteToLocal(folderId);

      // File stays in staging — no library dir to move to
      expect(trackFile.existsSync(), isTrue);
      final files = await repo.getFilesForBook(folderId);
      expect(files[0].localPath, trackFile.path);
    });

    test('skips files already in the final dir (backward compat)', () async {
      final (:positionService, :repo) = await _makeRepo();
      const folderId = 'folder4';
      const folderName = 'Already Promoted';
      final libDir = await Directory('${tempDir.path}/lib4').create();
      final bookDir =
          await Directory('${libDir.path}/$folderName').create(recursive: true);

      await repo.upsertDriveBook(_bookRecord(folderId, folderName));

      // File is already in the final library dir (e.g. downloaded with old code)
      final trackFile = File('${bookDir.path}/track.mp3');
      await trackFile.writeAsBytes([9]);

      await repo.upsertFile(_fileRecord(folderId, 0, 'track.mp3',
          state: DriveDownloadState.done,
          localPath: trackFile.path));

      final prefs = _StubPrefs(libraryPath: libDir.path);
      final service = _makeService(repo, prefs);

      await service.promoteToLocal(folderId);

      // File must still exist and DB path must be unchanged
      expect(trackFile.existsSync(), isTrue);
      final files = await repo.getFilesForBook(folderId);
      expect(files[0].localPath, trackFile.path);
    });

    test('moves cover from staging to final dir during promotion', () async {
      final (:positionService, :repo) = await _makeRepo();
      const folderId = 'folder5';
      const folderName = 'Cover Move';
      final libDir = await Directory('${tempDir.path}/lib5').create();

      await repo.upsertDriveBook(_bookRecord(folderId, folderName));

      final stagingPath = '${tempDir.path}/drive_books/$folderId';
      await Directory(stagingPath).create(recursive: true);
      final coverFile = File('$stagingPath/cover.jpg');
      await coverFile.writeAsBytes([0xFF, 0xD8]);
      final trackFile = File('$stagingPath/track.mp3');
      await trackFile.writeAsBytes([1]);

      await repo.upsertFile(_fileRecord(folderId, 0, 'track.mp3',
          state: DriveDownloadState.done,
          localPath: trackFile.path));

      final prefs = _StubPrefs(libraryPath: libDir.path);
      final service = _makeService(repo, prefs);

      await service.promoteToLocal(folderId);

      expect(
          File('${libDir.path}/$folderName/cover.jpg').existsSync(), isTrue);
      expect(coverFile.existsSync(), isFalse);
    });
  });
}
