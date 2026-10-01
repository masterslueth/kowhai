import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:kowhai/services/drive_book_repository.dart';
import 'package:kowhai/services/position_service.dart';

/// Opens a fresh in-memory DB matching the production schema (version 3).
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
  final positionService = PositionService.withDatabase(db);
  return (
    positionService: positionService,
    repo: DriveBookRepository(positionService),
  );
}

DriveBookRecord _book(String folderId,
        {String name = 'Book', List<String> fileIds = const []}) =>
    DriveBookRecord(
      folderId: folderId,
      folderName: name,
      rootFolderId: 'root',
      isShared: false,
      accountEmail: 'user@example.com',
      addedAt: 1000,
      coverFileId: 'cover-$folderId',
      audioFileIds: fileIds,
    );

DriveFileRecord _file(String folderId, int index,
        {DriveDownloadState state = DriveDownloadState.none,
        String? localPath}) =>
    DriveFileRecord(
      folderId: folderId,
      fileIndex: index,
      fileId: '$folderId-$index',
      fileName: 'track${index.toString().padLeft(2, '0')}.mp3',
      mimeType: 'audio/mpeg',
      sizeBytes: 1024 * (index + 1),
      downloadState: state,
      localPath: localPath,
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Record map round-trips', () {
    test('DriveBookRecord.toMap/fromMap preserves fields', () {
      final record = _book('F1', name: 'My Book', fileIds: ['a', 'b']);
      final map = record.toMap();
      final back = DriveBookRecord.fromMap(map, ['a', 'b']);
      expect(back.folderId, 'F1');
      expect(back.folderName, 'My Book');
      expect(back.isShared, isFalse);
      expect(back.accountEmail, 'user@example.com');
      expect(back.addedAt, 1000);
      expect(back.coverFileId, 'cover-F1');
      expect(back.audioFileIds, ['a', 'b']);
    });

    test('DriveFileRecord round-trips for each download state', () {
      for (final state in DriveDownloadState.values) {
        final record = _file('F', 3, state: state, localPath: '/tmp/x.mp3');
        final back = DriveFileRecord.fromMap(record.toMap());
        expect(back.downloadState, state, reason: 'state: $state');
        expect(back.folderId, 'F');
        expect(back.fileIndex, 3);
        expect(back.localPath, '/tmp/x.mp3');
      }
    });

    test('DriveFileRecord accepts unknown download_state as none', () {
      final map = _file('F', 0).toMap();
      map['download_state'] = 'gibberish';
      expect(DriveFileRecord.fromMap(map).downloadState,
          DriveDownloadState.none);
    });
  });

  group('DriveBookRepository', () {
    late DriveBookRepository repo;

    setUp(() async {
      repo = (await _makeRepo()).repo;
    });

    test('upsertDriveBook + getDriveBook round-trips', () async {
      await repo.upsertDriveBook(_book('F1', name: 'A'));
      final got = await repo.getDriveBook('F1');
      expect(got, isNotNull);
      expect(got!.folderName, 'A');
      expect(got.audioFileIds, isEmpty);
    });

    test('getDriveBook returns null for missing folder', () async {
      expect(await repo.getDriveBook('missing'), isNull);
    });

    test('upsertDriveBook replaces on conflict', () async {
      await repo.upsertDriveBook(_book('F1', name: 'First'));
      await repo.upsertDriveBook(_book('F1', name: 'Second'));
      final got = await repo.getDriveBook('F1');
      expect(got?.folderName, 'Second');
    });

    test('getFilesForBook returns files ordered by fileIndex', () async {
      await repo.upsertDriveBook(_book('F1'));
      await repo.upsertFile(_file('F1', 2));
      await repo.upsertFile(_file('F1', 0));
      await repo.upsertFile(_file('F1', 1));

      final files = await repo.getFilesForBook('F1');
      expect(files.map((f) => f.fileIndex), [0, 1, 2]);
    });

    test('getAllDriveBooks returns each book with its ordered file IDs',
        () async {
      await repo.upsertDriveBook(_book('F1', name: 'Alpha'));
      await repo.upsertFile(_file('F1', 1));
      await repo.upsertFile(_file('F1', 0));

      await repo.upsertDriveBook(_book('F2', name: 'Beta'));
      await repo.upsertFile(_file('F2', 0));

      final all = await repo.getAllDriveBooks();
      expect(all.length, 2);
      final f1 = all.firstWhere((b) => b.folderId == 'F1');
      expect(f1.audioFileIds, ['F1-0', 'F1-1']);
    });

    test('updateFileState persists and optionally sets localPath', () async {
      await repo.upsertDriveBook(_book('F1'));
      await repo.upsertFile(_file('F1', 0));

      await repo.updateFileState('F1', 0, DriveDownloadState.downloading);
      var files = await repo.getFilesForBook('F1');
      expect(files.first.downloadState, DriveDownloadState.downloading);
      expect(files.first.localPath, isNull);

      await repo.updateFileState('F1', 0, DriveDownloadState.done,
          localPath: '/tmp/done.mp3');
      files = await repo.getFilesForBook('F1');
      expect(files.first.downloadState, DriveDownloadState.done);
      expect(files.first.localPath, '/tmp/done.mp3');
    });

    test('resetBookDownloads resets every file to none', () async {
      await repo.upsertDriveBook(_book('F1'));
      await repo.upsertFile(
          _file('F1', 0, state: DriveDownloadState.done, localPath: '/x'));
      await repo.upsertFile(_file('F1', 1, state: DriveDownloadState.error));

      await repo.resetBookDownloads('F1');

      final files = await repo.getFilesForBook('F1');
      expect(files.every((f) => f.downloadState == DriveDownloadState.none),
          isTrue);
      // localPath must be preserved so re-downloads reuse the same location.
      expect(files.firstWhere((f) => f.fileIndex == 0).localPath, '/x');
    });

    test('deleteDriveBook removes book and its files', () async {
      await repo.upsertDriveBook(_book('F1'));
      await repo.upsertFile(_file('F1', 0));
      await repo.upsertFile(_file('F1', 1));

      await repo.deleteDriveBook('F1');

      expect(await repo.getDriveBook('F1'), isNull);
      expect(await repo.getFilesForBook('F1'), isEmpty);
    });

    test('deleteDriveBook does not affect other books', () async {
      await repo.upsertDriveBook(_book('F1'));
      await repo.upsertDriveBook(_book('F2'));
      await repo.upsertFile(_file('F2', 0));

      await repo.deleteDriveBook('F1');

      expect(await repo.getDriveBook('F2'), isNotNull);
      expect((await repo.getFilesForBook('F2')).length, 1);
    });

    test('updateFileLocalPath updates only local_path, preserves state',
        () async {
      await repo.upsertDriveBook(_book('F1'));
      await repo.upsertFile(_file('F1', 0,
          state: DriveDownloadState.none, localPath: '/old/path.mp3'));

      await repo.updateFileLocalPath('F1', 0, '/new/path.mp3');

      final files = await repo.getFilesForBook('F1');
      expect(files.first.localPath, '/new/path.mp3');
      expect(files.first.downloadState, DriveDownloadState.none);
    });

    test('updateFileLocalPath does not affect other files', () async {
      await repo.upsertDriveBook(_book('F1'));
      await repo.upsertFile(
          _file('F1', 0, state: DriveDownloadState.done, localPath: '/a.mp3'));
      await repo.upsertFile(_file('F1', 1, localPath: '/b.mp3'));

      await repo.updateFileLocalPath('F1', 1, '/b-new.mp3');

      final files = await repo.getFilesForBook('F1');
      expect(files.firstWhere((f) => f.fileIndex == 0).localPath, '/a.mp3');
      expect(files.firstWhere((f) => f.fileIndex == 1).localPath, '/b-new.mp3');
    });

    test('resetStaleDownloads resets missing-file rows to none', () async {
      await repo.upsertDriveBook(_book('F1'));
      // localPath points to a non-existent file.
      await repo.upsertFile(_file('F1', 0,
          state: DriveDownloadState.downloading,
          localPath: '/does/not/exist.mp3'));

      await repo.resetStaleDownloads();

      final files = await repo.getFilesForBook('F1');
      expect(files.first.downloadState, DriveDownloadState.none);
    });

    test('resetStaleDownloads marks complete file as done', () async {
      final tmpDir = await Directory.systemTemp.createTemp('avrepo_');
      addTearDown(() => tmpDir.delete(recursive: true));

      final tmpFile = File('${tmpDir.path}/track.mp3');
      await tmpFile.writeAsBytes(List.filled(1024, 0)); // 1024 bytes

      await repo.upsertDriveBook(_book('F2'));
      await repo.upsertFile(DriveFileRecord(
        folderId: 'F2',
        fileIndex: 0,
        fileId: 'f2-0',
        fileName: 'track.mp3',
        mimeType: 'audio/mpeg',
        sizeBytes: 1024, // exact match
        downloadState: DriveDownloadState.downloading,
        localPath: tmpFile.path,
      ));

      await repo.resetStaleDownloads();

      final files = await repo.getFilesForBook('F2');
      expect(files.first.downloadState, DriveDownloadState.done,
          reason: 'complete file should be promoted to done');
      expect(tmpFile.existsSync(), isTrue,
          reason: 'complete file must not be deleted');
    });

    test('resetStaleDownloads deletes partial file and resets to none',
        () async {
      final tmpDir = await Directory.systemTemp.createTemp('avrepo_');
      addTearDown(() => tmpDir.delete(recursive: true));

      final tmpFile = File('${tmpDir.path}/track.mp3');
      await tmpFile.writeAsBytes(List.filled(512, 0)); // only half the bytes

      await repo.upsertDriveBook(_book('F3'));
      await repo.upsertFile(DriveFileRecord(
        folderId: 'F3',
        fileIndex: 0,
        fileId: 'f3-0',
        fileName: 'track.mp3',
        mimeType: 'audio/mpeg',
        sizeBytes: 1024, // expected 1 KB
        downloadState: DriveDownloadState.downloading,
        localPath: tmpFile.path,
      ));

      await repo.resetStaleDownloads();

      final files = await repo.getFilesForBook('F3');
      expect(files.first.downloadState, DriveDownloadState.none,
          reason: 'partial file should reset to none');
      expect(tmpFile.existsSync(), isFalse,
          reason: 'partial file must be deleted');
    });

    test('resetStaleDownloads leaves non-downloading rows untouched', () async {
      await repo.upsertDriveBook(_book('F4'));
      await repo.upsertFile(
          _file('F4', 0, state: DriveDownloadState.done, localPath: '/x'));
      await repo.upsertFile(_file('F4', 1, state: DriveDownloadState.error));

      await repo.resetStaleDownloads();

      final files = await repo.getFilesForBook('F4');
      expect(files.firstWhere((f) => f.fileIndex == 0).downloadState,
          DriveDownloadState.done);
      expect(files.firstWhere((f) => f.fileIndex == 1).downloadState,
          DriveDownloadState.error);
    });

    test('resetStaleDownloads trusts non-empty file when expected size is unknown',
        () async {
      final tmpDir = await Directory.systemTemp.createTemp('avrepo_');
      addTearDown(() => tmpDir.delete(recursive: true));

      final tmpFile = File('${tmpDir.path}/track.mp3');
      await tmpFile.writeAsBytes(List.filled(256, 0));

      await repo.upsertDriveBook(_book('F5'));
      await repo.upsertFile(DriveFileRecord(
        folderId: 'F5',
        fileIndex: 0,
        fileId: 'f5-0',
        fileName: 'track.mp3',
        mimeType: 'audio/mpeg',
        sizeBytes: 0, // size unknown at record time
        downloadState: DriveDownloadState.downloading,
        localPath: tmpFile.path,
      ));

      await repo.resetStaleDownloads();

      final files = await repo.getFilesForBook('F5');
      expect(files.first.downloadState, DriveDownloadState.done,
          reason:
              'unknown-size records must not delete possibly-complete data');
      expect(tmpFile.existsSync(), isTrue);
    });
  });

  group('DriveBookRepository upsert with foreign keys ON', () {
    // Regression guard for the ON DELETE CASCADE landmine. Production now
    // enables `PRAGMA foreign_keys = ON`. SQLite implements
    // ConflictAlgorithm.replace as DELETE + INSERT, so a REPLACE on
    // drive_books would cascade-delete every drive_book_files row for that
    // book on each re-import.
    test('re-upserting a book does not cascade-delete its file rows', () async {
      final (:positionService, :repo) = await _makeRepo();
      final db = await positionService.sharedDb;
      await db.execute('PRAGMA foreign_keys = ON');

      await repo.upsertDriveBook(_book('FK1'));
      await repo.upsertFile(DriveFileRecord(
        folderId: 'FK1',
        fileIndex: 0,
        fileId: 'fk1-0',
        fileName: 'a.mp3',
        mimeType: 'audio/mpeg',
        sizeBytes: 10,
        downloadState: DriveDownloadState.done,
        localPath: '/tmp/a.mp3',
      ));
      expect((await repo.getFilesForBook('FK1')).length, 1);

      // Simulate a Drive re-scan touching the same book.
      await repo.upsertDriveBook(_book('FK1'));

      final after = await repo.getFilesForBook('FK1');
      expect(after.length, 1,
          reason: 'REPLACE-as-DELETE would have cascaded this away');
      expect(after.first.localPath, '/tmp/a.mp3',
          reason: 'download state must survive a book re-import');
    });

    test('a re-import without a cover does not clear the stored cover',
        () async {
      final (:positionService, :repo) = await _makeRepo();

      final withCover = DriveBookRecord(
        folderId: 'FK2',
        folderName: 'Book',
        rootFolderId: 'root',
        isShared: false,
        accountEmail: 'a@b.c',
        addedAt: 1,
        coverFileId: 'cover-123',
        audioFileIds: const [],
      );
      await repo.upsertDriveBook(withCover);

      final withoutCover = DriveBookRecord(
        folderId: 'FK2',
        folderName: 'Book',
        rootFolderId: 'root',
        isShared: false,
        accountEmail: 'a@b.c',
        addedAt: 2,
        coverFileId: null,
        audioFileIds: const [],
      );
      await repo.upsertDriveBook(withoutCover);

      expect((await repo.getDriveBook('FK2'))?.coverFileId, 'cover-123');
    });

    test('upsertDriveBookWithFiles writes the book and all files atomically',
        () async {
      final (:positionService, :repo) = await _makeRepo();

      await repo.upsertDriveBookWithFiles(_book('FK3'), [
        DriveFileRecord(
          folderId: 'FK3',
          fileIndex: 0,
          fileId: 'fk3-0',
          fileName: 'a.mp3',
          mimeType: 'audio/mpeg',
          sizeBytes: 1,
          downloadState: DriveDownloadState.none,
          localPath: null,
        ),
        DriveFileRecord(
          folderId: 'FK3',
          fileIndex: 1,
          fileId: 'fk3-1',
          fileName: 'b.mp3',
          mimeType: 'audio/mpeg',
          sizeBytes: 2,
          downloadState: DriveDownloadState.none,
          localPath: null,
        ),
      ]);

      expect((await repo.getFilesForBook('FK3')).length, 2);
      expect((await repo.getDriveBook('FK3'))?.audioFileIds.length, 2);
    });
  });
}
