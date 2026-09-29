import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../models/audiobook.dart';
import '../models/bookmark.dart';
import '../utils/formatters.dart';

// Callback type for notifying that a position was saved.
typedef PositionSavedCallback = void Function();

class PositionService {
  PositionService({this.onPositionSaved});

  /// Called after every successful [savePosition].
  final PositionSavedCallback? onPositionSaved;

  /// Injects an already-opened [Database] — for use in tests only.
  @visibleForTesting
  PositionService.withDatabase(Database db, {this.onPositionSaved})
      : _db = db;

  Database? _db;

  /// Direct database access for test assertions — do not use in production.
  @visibleForTesting
  Future<Database> get databaseForTesting => _database;

  /// Shared DB access for DriveBookRepository (same file, same instance).
  Future<Database> get sharedDb => _database;

  Future<Database> get _database async {
    _db ??= await _openDb();
    return _db!;
  }

  Future<Database> _openDb() async {
    final dir = await getApplicationDocumentsDirectory();
    return openDatabase(
      '${dir.path}/kowhai_positions.db',
      version: 5,
      onConfigure: (db) async {
        // SQLite ships with foreign keys OFF per connection. The
        // drive_book_files DTD declares ON DELETE CASCADE, and
        // upsertDriveBook uses ConflictAlgorithm.replace (which SQLite
        // implements as DELETE + INSERT) - so leaving the pragma off is what
        // currently stops every Drive re-import from cascade-deleting that
        // book's file rows. Enabling it is correct, but only safe because
        // ConflictAlgorithm.replace is not used for those tables; a future
        // REPLACE there would now silently wipe file rows. Kept explicit and
        // documented rather than relying on the default.
        await db.execute('PRAGMA foreign_keys = ON');
      },
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
        // getLastPlayedBookPath / getAllPositions both ORDER BY updated_at DESC
        // over the whole table, which is a full scan plus sort on every call.
        await db.execute(
            'CREATE INDEX idx_positions_updated_at ON positions(updated_at DESC)');
        await createDriveTables(db);
        await createBookmarksTable(db);
      },
      onUpgrade: (db, oldVersion, newVersion) =>
          performUpgrades(db, oldVersion),
    );
  }

  /// The production upgrade chain, exposed for tests: the real onUpgrade
  /// delegates here, so tests exercise exactly what ships. Each step is
  /// additive and idempotent per version gate.
  @visibleForTesting
  static Future<void> performUpgrades(Database db, int oldVersion) async {
    if (oldVersion < 2) {
      await createDriveTables(db);
    }
    if (oldVersion < 3) {
      await db.execute('ALTER TABLE positions ADD COLUMN status TEXT');
    }
    if (oldVersion < 4) {
      await createBookmarksTable(db);
    }
    if (oldVersion < 5) {
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_positions_updated_at ON positions(updated_at DESC)');
    }
  }

  @visibleForTesting
  static Future<void> createBookmarksTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS bookmarks (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        book_path    TEXT NOT NULL,
        chapter_index INTEGER NOT NULL,
        position_ms  INTEGER NOT NULL,
        label        TEXT NOT NULL,
        notes        TEXT,
        created_at   INTEGER NOT NULL
      )
    ''');
    // IF NOT EXISTS: a bare CREATE aborts onUpgrade with a DatabaseException,
    // and since onUpgrade would keep failing on every launch there is no
    // recovery path. Idempotence is what the version gate assumes.
    await db.execute('CREATE INDEX IF NOT EXISTS idx_bookmarks_book_path '
        'ON bookmarks(book_path)');
  }

  @visibleForTesting
  static Future<void> createDriveTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS drive_books (
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
      CREATE TABLE IF NOT EXISTS drive_book_files (
        folder_id       TEXT NOT NULL,
        file_index      INTEGER NOT NULL,
        file_id         TEXT NOT NULL,
        file_name       TEXT NOT NULL,
        mime_type       TEXT NOT NULL,
        size_bytes      INTEGER NOT NULL DEFAULT 0,
        download_state  TEXT NOT NULL DEFAULT 'none',
        local_path      TEXT,
        PRIMARY KEY (folder_id, file_index),
        FOREIGN KEY (folder_id) REFERENCES drive_books(folder_id) ON DELETE CASCADE
      )
    ''');
  }

  Future<void> savePosition({
    required String bookPath,
    required int chapterIndex,
    required Duration position,
    required int globalPositionMs,
    required int totalDurationMs,
  }) async {
    final db = await _database;
    // UPSERT that never touches the explicit `status` column — a periodic or
    // pause-time save must not wipe a status the user set manually. (The
    // mirror-image invariant lives in setBookStatus below, which never
    // touches the position columns.) ConflictAlgorithm.replace would be wrong
    // here: SQLite REPLACE deletes the conflicting row, silently nulling
    // `status`.
    await db.rawInsert(
      'INSERT INTO positions '
      '(book_path, chapter_index, position_ms, global_position_ms, total_duration_ms, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(book_path) DO UPDATE SET '
      'chapter_index=excluded.chapter_index, '
      'position_ms=excluded.position_ms, '
      'global_position_ms=excluded.global_position_ms, '
      'total_duration_ms=excluded.total_duration_ms, '
      'updated_at=excluded.updated_at',
      [
        bookPath,
        chapterIndex,
        position.inMilliseconds,
        globalPositionMs,
        totalDurationMs,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    onPositionSaved?.call();
  }

  /// Repairs rows restored from legacy backups that only carried a global
  /// position: signature is `chapter_index == 0 && position_ms == 0 &&
  /// global_position_ms > 0`, which no genuine save can produce (for
  /// chapter 0, global == intra-chapter position by definition).
  ///
  /// Rewrites only `chapter_index`/`position_ms` via the pure inverse mapper —
  /// never `global_position_ms`, which status derivation reads — and never
  /// touches an explicit `status`. Idempotent; returns true when rewritten.
  Future<bool> repairFromGlobal(Audiobook book) async {
    if (book.chapterDurations.isEmpty) return false;
    final db = await _database;
    final rows = await db.query(
      'positions',
      columns: ['chapter_index', 'position_ms', 'global_position_ms'],
      where: 'book_path = ?',
      whereArgs: [book.path],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final row = rows.first;
    final chapterIndex = row['chapter_index'] as int? ?? 0;
    final positionMs = row['position_ms'] as int? ?? 0;
    final globalMs = row['global_position_ms'] as int? ?? 0;
    if (chapterIndex != 0 || positionMs != 0 || globalMs <= 0) return false;

    final mapped = globalToChapterPosition(globalMs, book.chapterDurations);
    await db.update(
      'positions',
      {
        'chapter_index': mapped.chapterIndex,
        'position_ms': mapped.position.inMilliseconds,
      },
      where: 'book_path = ?',
      whereArgs: [book.path],
    );
    return true;
  }

  Future<({int chapterIndex, Duration position})?> getPosition(
      String bookPath) async {
    final db = await _database;
    final rows = await db.query(
      'positions',
      where: 'book_path = ?',
      whereArgs: [bookPath],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return (
      chapterIndex: row['chapter_index'] as int,
      position: Duration(milliseconds: row['position_ms'] as int),
    );
  }

  Future<void> setBookStatus(String bookPath, BookStatus status) async {
    final db = await _database;
    // INSERT with zero position for brand-new books; on conflict only update
    // the status column so existing progress is never silently wiped.
    await db.rawInsert(
      'INSERT INTO positions '
      '(book_path, chapter_index, position_ms, global_position_ms, total_duration_ms, updated_at, status) '
      'VALUES (?, 0, 0, 0, 0, ?, ?) '
      'ON CONFLICT(book_path) DO UPDATE SET '
      'status=excluded.status, updated_at=excluded.updated_at',
      [bookPath, DateTime.now().millisecondsSinceEpoch, status.name],
    );
  }

  Future<void> updateBookStatus(String bookPath, BookStatus status) async {
    final db = await _database;
    // Only update status column if the row already exists, otherwise insert.
    final existing = await db.query('positions',
        where: 'book_path = ?', whereArgs: [bookPath], limit: 1);
    if (existing.isEmpty) {
      await setBookStatus(bookPath, status);
    } else {
      await db.update(
        'positions',
        {'status': status.name},
        where: 'book_path = ?',
        whereArgs: [bookPath],
      );
    }
  }

  Future<BookStatus> getBookStatus(String bookPath) async {
    final db = await _database;
    final rows = await db.query('positions',
        columns: ['status', 'global_position_ms', 'total_duration_ms'],
        where: 'book_path = ?',
        whereArgs: [bookPath],
        limit: 1);
    if (rows.isEmpty) return BookStatus.notStarted;
    return _statusFromRow(rows.first);
  }

  Future<Map<String, BookStatus>> getAllStatuses() async {
    final db = await _database;
    final rows = await db.query('positions',
        columns: ['book_path', 'status', 'global_position_ms', 'total_duration_ms']);
    final result = <String, BookStatus>{};
    for (final row in rows) {
      final path = row['book_path'] as String;
      result[path] = _statusFromRow(row);
    }
    return result;
  }

  // A finished book is one whose global position is within this many ms of
  // the total duration — covers files where the final chapter has trailing
  // silence or metadata the player never reaches.
  static const int _finishedThresholdMs = 60000;

  static BookStatus _statusFromRow(Map<String, Object?> row) {
    final statusStr = row['status'] as String?;
    if (statusStr != null) {
      return BookStatus.values.firstWhere((s) => s.name == statusStr,
          orElse: () => BookStatus.notStarted);
    }
    return _deriveStatus(
      row['global_position_ms'] as int,
      row['total_duration_ms'] as int,
    );
  }

  @visibleForTesting
  static BookStatus deriveStatusForTesting(int globalMs, int totalMs) =>
      _deriveStatus(globalMs, totalMs);

  static BookStatus _deriveStatus(int globalMs, int totalMs) {
    if (globalMs <= 0) return BookStatus.notStarted;
    // The 60 s tail allowance only makes sense for a book long enough to have
    // one. For a 20 s clip the bound goes negative, so ANY progress at all
    // satisfied it and the book reported as finished the moment you pressed
    // play. Clamp the threshold to a fraction of the book instead.
    if (totalMs > 0 && globalMs >= totalMs - _tailAllowance(totalMs)) {
      return BookStatus.finished;
    }
    return BookStatus.inProgress;
  }

  /// Trailing allowance for the "finished" threshold: [_finishedThresholdMs],
  /// but never more than half the book, so short media cannot be reported
  /// finished before it has meaningfully played.
  static int _tailAllowance(int totalMs) {
    final half = totalMs ~/ 2;
    return _finishedThresholdMs < half ? _finishedThresholdMs : half;
  }

  // ── Bookmark CRUD ──────────────────────────────────────────────────────────

  Future<Bookmark> addBookmark(Bookmark bookmark) async {
    final db = await _database;
    final id = await db.insert('bookmarks', bookmark.toMap());
    return Bookmark(
      id: id,
      bookPath: bookmark.bookPath,
      chapterIndex: bookmark.chapterIndex,
      positionMs: bookmark.positionMs,
      label: bookmark.label,
      notes: bookmark.notes,
      createdAt: bookmark.createdAt,
    );
  }

  Future<List<Bookmark>> getBookmarks(String bookPath) async {
    final db = await _database;
    final rows = await db.query(
      'bookmarks',
      where: 'book_path = ?',
      whereArgs: [bookPath],
      orderBy: 'position_ms ASC',
    );
    return rows.map(Bookmark.fromMap).toList();
  }

  Future<void> deleteBookmark(int id) async {
    final db = await _database;
    await db.delete('bookmarks', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateBookmark(int id,
      {required String label, String? notes}) async {
    final db = await _database;
    await db.update(
      'bookmarks',
      {'label': label, 'notes': notes},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<String?> getLastPlayedBookPath() async {
    final db = await _database;
    final rows = await db.query(
      'positions',
      orderBy: 'updated_at DESC',
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['book_path'] as String?;
  }

  Future<List<BookProgress>> getAllPositions() async {
    final db = await _database;
    final rows =
        await db.query('positions', orderBy: 'updated_at DESC');
    return rows
        .map((r) => (
              bookPath: r['book_path'] as String,
              chapterIndex: r['chapter_index'] as int? ?? 0,
              positionMs: r['position_ms'] as int? ?? 0,
              globalPositionMs: r['global_position_ms'] as int,
              totalDurationMs: r['total_duration_ms'] as int,
              updatedAt: r['updated_at'] as int,
            ))
        .toList();
  }
}

typedef BookProgress = ({
  String bookPath,
  int chapterIndex,
  int positionMs,
  int globalPositionMs,
  int totalDurationMs,
  int updatedAt,
});
