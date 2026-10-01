import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'position_service.dart';

enum DriveDownloadState { none, downloading, done, error }

class DriveBookRecord {
  final String folderId;
  final String folderName;
  final String rootFolderId;
  final bool isShared;
  final String accountEmail;
  final int addedAt;
  final String? coverFileId;
  final List<String> audioFileIds; // ordered list of Drive file IDs

  const DriveBookRecord({
    required this.folderId,
    required this.folderName,
    required this.rootFolderId,
    required this.isShared,
    required this.accountEmail,
    required this.addedAt,
    this.coverFileId,
    required this.audioFileIds,
  });

  Map<String, Object?> toMap() => {
        'folder_id': folderId,
        'folder_name': folderName,
        'root_folder_id': rootFolderId,
        'is_shared': isShared ? 1 : 0,
        'account_email': accountEmail,
        'added_at': addedAt,
        'cover_file_id': coverFileId,
      };

  static DriveBookRecord fromMap(Map<String, Object?> map, List<String> fileIds) =>
      DriveBookRecord(
        folderId: map['folder_id'] as String,
        folderName: map['folder_name'] as String,
        rootFolderId: map['root_folder_id'] as String,
        isShared: (map['is_shared'] as int) != 0,
        accountEmail: map['account_email'] as String,
        addedAt: map['added_at'] as int,
        coverFileId: map['cover_file_id'] as String?,
        audioFileIds: fileIds,
      );
}

class DriveFileRecord {
  final String folderId;
  final int fileIndex;
  final String fileId;
  final String fileName;
  final String mimeType;
  final int sizeBytes;
  final DriveDownloadState downloadState;
  final String? localPath;

  const DriveFileRecord({
    required this.folderId,
    required this.fileIndex,
    required this.fileId,
    required this.fileName,
    required this.mimeType,
    required this.sizeBytes,
    required this.downloadState,
    this.localPath,
  });

  Map<String, Object?> toMap() => {
        'folder_id': folderId,
        'file_index': fileIndex,
        'file_id': fileId,
        'file_name': fileName,
        'mime_type': mimeType,
        'size_bytes': sizeBytes,
        'download_state': _stateToString(downloadState),
        'local_path': localPath,
      };

  static DriveFileRecord fromMap(Map<String, Object?> map) => DriveFileRecord(
        folderId: map['folder_id'] as String,
        fileIndex: map['file_index'] as int,
        fileId: map['file_id'] as String,
        fileName: map['file_name'] as String,
        mimeType: map['mime_type'] as String,
        sizeBytes: map['size_bytes'] as int,
        downloadState: _stateFromString(map['download_state'] as String),
        localPath: map['local_path'] as String?,
      );

  static String _stateToString(DriveDownloadState s) => switch (s) {
        DriveDownloadState.none => 'none',
        DriveDownloadState.downloading => 'downloading',
        DriveDownloadState.done => 'done',
        DriveDownloadState.error => 'error',
      };

  static DriveDownloadState _stateFromString(String s) => switch (s) {
        'downloading' => DriveDownloadState.downloading,
        'done' => DriveDownloadState.done,
        'error' => DriveDownloadState.error,
        _ => DriveDownloadState.none,
      };
}

class DriveBookRepository {
  final PositionService _positionService;

  DriveBookRepository(this._positionService);

  Future<Database> get _db => _positionService.sharedDb;

  /// Inserts [record] and all of [files] in a single transaction.
  ///
  /// Previously these were N+1 independent writes, so a cancellation or a
  /// thrown cast midway left a `drive_books` row with a partial file set.
  /// Because rescanDrive skips folders that already have a record, such a row
  /// was never repaired: totalFileCount stayed wrong and the book sat
  /// permanently "half downloaded".
  Future<void> upsertDriveBookWithFiles(
      DriveBookRecord record, List<DriveFileRecord> files) async {
    final db = await _db;
    await db.transaction((txn) async {
      await _upsertBook(txn, record);
      for (final f in files) {
        await _upsertFile(txn, f);
      }
    });
  }

  Future<void> upsertDriveBook(DriveBookRecord record) async {
    final db = await _db;
    await _upsertBook(db, record);
  }

  Future<void> _upsertBook(DatabaseExecutor db, DriveBookRecord record) async {
    // Deliberately an UPSERT, not ConflictAlgorithm.replace. SQLite implements
    // REPLACE as DELETE + INSERT, and drive_book_files has ON DELETE CASCADE
    // on folder_id - so a REPLACE here would wipe every downloaded-file row
    // for the book on each re-import (now that foreign_keys is enabled).
    // cover_file_id is preserved with COALESCE so a re-scan that did not
    // resolve a cover does not clear one already on record.
    await db.rawInsert(
      'INSERT INTO drive_books '
      '(folder_id, folder_name, root_folder_id, is_shared, account_email, added_at, cover_file_id) '
      'VALUES (?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(folder_id) DO UPDATE SET '
      'folder_name=excluded.folder_name, '
      'root_folder_id=excluded.root_folder_id, '
      'is_shared=excluded.is_shared, '
      'account_email=excluded.account_email, '
      'added_at=excluded.added_at, '
      'cover_file_id=COALESCE(excluded.cover_file_id, drive_books.cover_file_id)',
      [
        record.folderId,
        record.folderName,
        record.rootFolderId,
        record.isShared ? 1 : 0,
        record.accountEmail,
        record.addedAt,
        record.coverFileId,
      ],
    );
  }

  Future<void> upsertFile(DriveFileRecord record) async {
    final db = await _db;
    await _upsertFile(db, record);
  }

  /// Safe to use REPLACE here: drive_book_files has no child tables, so
  /// DELETE + INSERT cannot cascade anywhere.
  Future<void> _upsertFile(DatabaseExecutor db, DriveFileRecord record) async {
    await db.insert('drive_book_files', record.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<DriveBookRecord>> getAllDriveBooks() async {
    final db = await _db;
    // One query for all books plus one for all files, instead of a round-trip
    // per book. getAllDriveBooks runs several times per library refresh
    // (loadDriveBooks, driveBookDirs, removeUndownloadedBooks, reseedAll), so
    // the old shape cost O(books) sequential queries each time.
    final bookRows = await db.query('drive_books');
    if (bookRows.isEmpty) return [];

    final allFiles = await db.query('drive_book_files',
        orderBy: 'folder_id ASC, file_index ASC');
    final fileIdsByFolder = <String, List<String>>{};
    for (final row in allFiles) {
      (fileIdsByFolder[row['folder_id'] as String] ??= [])
          .add(row['file_id'] as String);
    }

    return [
      for (final row in bookRows)
        DriveBookRecord.fromMap(
            row, fileIdsByFolder[row['folder_id'] as String] ?? const []),
    ];
  }

  Future<DriveBookRecord?> getDriveBook(String folderId) async {
    final db = await _db;
    final rows = await db.query(
      'drive_books',
      where: 'folder_id = ?',
      whereArgs: [folderId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final fileRows = await db.query(
      'drive_book_files',
      where: 'folder_id = ?',
      whereArgs: [folderId],
      orderBy: 'file_index ASC',
    );
    final fileIds = fileRows.map((r) => r['file_id'] as String).toList();
    return DriveBookRecord.fromMap(rows.first, fileIds);
  }

  /// Resets all files for a book back to [DriveDownloadState.none].
  /// Keeps local_path so re-downloads go to the same location.
  Future<void> resetBookDownloads(String folderId) async {
    final db = await _db;
    await db.update(
      'drive_book_files',
      {'download_state': 'none'},
      where: 'folder_id = ?',
      whereArgs: [folderId],
    );
  }

  /// Resets every file for a book to 'none' and clears its cached local_path.
  ///
  /// [resetBookDownloads] deliberately KEEPS local_path so a re-download lands
  /// in the same place. That is wrong after the files have actually been
  /// deleted from disk: the stale path would make the library advertise audio
  /// that no longer exists, and it is never revisited (resetStaleDownloads
  /// only rescues 'downloading' rows).
  Future<void> reseedFolderStates(String folderId) async {
    final db = await _db;
    await db.update(
      'drive_book_files',
      {'download_state': 'none', 'local_path': null},
      where: 'folder_id = ?',
      whereArgs: [folderId],
    );
  }

  Future<void> deleteDriveBook(String folderId) async {
    final db = await _db;
    // Foreign keys are enabled in PositionService.onConfigure, so the CASCADE
    // would handle the child rows. Both deletes are kept explicit and wrapped
    // in a transaction so the book never half-disappears, and so behaviour
    // does not silently depend on the pragma.
    await db.transaction((txn) async {
      await txn.delete('drive_book_files',
          where: 'folder_id = ?', whereArgs: [folderId]);
      await txn.delete('drive_books',
          where: 'folder_id = ?', whereArgs: [folderId]);
    });
  }

  Future<List<DriveFileRecord>> getFilesForBook(String folderId) async {
    final db = await _db;
    final rows = await db.query(
      'drive_book_files',
      where: 'folder_id = ?',
      whereArgs: [folderId],
      orderBy: 'file_index ASC',
    );
    return rows.map(DriveFileRecord.fromMap).toList();
  }

  Future<void> updateFileState(
    String folderId,
    int fileIndex,
    DriveDownloadState state, {
    String? localPath,
  }) async {
    final db = await _db;
    final values = <String, Object?>{
      'download_state': DriveFileRecord._stateToString(state),
    };
    if (localPath != null) values['local_path'] = localPath;
    await db.update(
      'drive_book_files',
      values,
      where: 'folder_id = ? AND file_index = ?',
      whereArgs: [folderId, fileIndex],
    );
  }

  /// Updates only the local_path for a specific file, leaving download_state unchanged.
  Future<void> updateFileLocalPath(
      String folderId, int fileIndex, String localPath) async {
    final db = await _db;
    await db.update(
      'drive_book_files',
      {'local_path': localPath},
      where: 'folder_id = ? AND file_index = ?',
      whereArgs: [folderId, fileIndex],
    );
  }

  /// Recovers stale 'downloading' state on startup (e.g. after process kill).
  ///
  /// A file is considered complete when its on-disk size reaches the expected
  /// size stored in the DB (`>=` covers the race where the download finished
  /// but the DB update was killed before it could be written). When the
  /// expected size is unknown (0), any non-empty file is trusted rather than
  /// deleting possibly-complete user data. A partial file is deleted and the
  /// record reset to 'none' so the download restarts cleanly.
  ///
  /// File IO failures are logged and skipped: this runs before the first frame
  /// (main.dart), and one unreadable file must never block app launch.
  Future<void> resetStaleDownloads() async {
    final db = await _db;
    final stale = await db.query(
      'drive_book_files',
      where: "download_state = 'downloading'",
    );
    for (final row in stale) {
      final localPath = row['local_path'] as String?;
      final expectedSize = row['size_bytes'] as int? ?? 0;

      bool isComplete = false;
      if (localPath != null) {
        try {
          final file = File(localPath);
          if (await file.exists()) {
            final actualSize = await file.length();
            if ((expectedSize > 0 && actualSize >= expectedSize) ||
                (expectedSize == 0 && actualSize > 0)) {
              isComplete = true;
            } else {
              await file.delete(); // remove partial so next download starts fresh
            }
          }
        } catch (e) {
          debugPrint('[Kowhai:DriveRepo] recovery skipped $localPath: $e');
        }
      }

      await db.update(
        'drive_book_files',
        {'download_state': isComplete ? 'done' : 'none'},
        where: 'folder_id = ? AND file_index = ?',
        whereArgs: [row['folder_id'], row['file_index']],
      );
    }
  }
}
