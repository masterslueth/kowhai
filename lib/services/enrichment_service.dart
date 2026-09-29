import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import '../models/audiobook.dart';
import 'telemetry_service.dart';

const _openLibrarySearchUrl = 'https://openlibrary.org/search.json';
const _openLibraryCoverUrl = 'https://covers.openlibrary.org/b/id';

class EnrichmentService {
  EnrichmentService({http.Client? client})
      : _client = client ?? http.Client(),
        _usingInjectedClient = client != null;

  /// Injects an already-opened [Database] and optional [http.Client] — for use in tests only.
  @visibleForTesting
  EnrichmentService.withDatabase(Database db, {http.Client? client})
      : _client = client ?? http.Client(),
        _db = db,
        _usingInjectedClient = client != null;

  static void _log(String msg) => debugPrint('[Kowhai:Enrichment] $msg');

  http.Client _client;

  /// True when the client came from DI (tests). An injected client closed by
  /// [cancel] is NOT replaced — tests observe the close; production always
  /// owns its client, which is recreated after a cancel on the next run.
  final bool _usingInjectedClient;
  Database? _db;
  bool _processing = false;
  bool _cancelled = false;
  final _pendingBooks = <Audiobook>[];
  bool _closedOwnedClient = false;

  final _controller =
      StreamController<({String bookPath, String coverPath})>.broadcast();
  Stream<({String bookPath, String coverPath})> get onCoverFetched =>
      _controller.stream;

  /// Book paths currently being enriched. UIs can watch this to show a
  /// per-card spinner while a cover fetch is in flight.
  final ValueNotifier<Set<String>> enrichingPaths =
      ValueNotifier<Set<String>>(const {});

  /// Book paths whose enrichment finished without finding a cover this
  /// session. UIs can use this to render a distinct "no cover available"
  /// placeholder instead of the default unprocessed-looking one.
  final ValueNotifier<Set<String>> failedPaths =
      ValueNotifier<Set<String>>(const {});

  void _markEnriching(String path) {
    enrichingPaths.value = {...enrichingPaths.value, path};
  }

  void _unmarkEnriching(String path) {
    final next = {...enrichingPaths.value}..remove(path);
    enrichingPaths.value = next;
  }

  void _markFailed(String path) {
    failedPaths.value = {...failedPaths.value, path};
  }

  void _clearFailed(String path) {
    if (!failedPaths.value.contains(path)) return;
    final next = {...failedPaths.value}..remove(path);
    failedPaths.value = next;
  }

  Future<Database> get _database async {
    _db ??= await _openDb();
    return _db!;
  }

  Future<Database> _openDb() async {
    final dir = await getApplicationDocumentsDirectory();
    return openDatabase(
      '${dir.path}/kowhai_enrichment.db',
      version: 1,
      onCreate: (db, _) => db.execute('''
        CREATE TABLE enrichment (
          book_path TEXT PRIMARY KEY,
          enriched INTEGER NOT NULL DEFAULT 0,
          cover_path TEXT,
          last_enriched_date INTEGER,
          last_attempted_date INTEGER
        )
      '''),
    );
  }

  Future<({bool enriched, String? coverPath, DateTime? lastAttempted})>
      getStatus(String bookPath) async {
    final db = await _database;
    final rows = await db.query(
      'enrichment',
      where: 'book_path = ?',
      whereArgs: [bookPath],
      limit: 1,
    );
    if (rows.isEmpty) {
      return (enriched: false, coverPath: null, lastAttempted: null);
    }
    final row = rows.first;
    final ms = row['last_attempted_date'] as int?;
    return (
      enriched: (row['enriched'] as int) == 1,
      coverPath: row['cover_path'] as String?,
      lastAttempted:
          ms != null ? DateTime.fromMillisecondsSinceEpoch(ms) : null,
    );
  }

  /// Returns all previously enriched cover paths keyed by book path.
  Future<Map<String, String>> getAllEnrichedCovers() async {
    final db = await _database;
    final rows = await db.query(
      'enrichment',
      where: 'enriched = 1 AND cover_path IS NOT NULL',
    );
    return {
      for (final row in rows)
        row['book_path'] as String: row['cover_path'] as String,
    };
  }

  /// Processes [books] in the background, fetching covers for those missing one.
  ///
  /// If called while a previous batch is still running, the new books are
  /// queued and will be processed once the current batch completes.
  Future<void> enqueueBooks(List<Audiobook> books) async {
    if (_processing) {
      _pendingBooks.addAll(books);
      return;
    }
    _processing = true;
    _cancelled = false;
    if (!_usingInjectedClient && _closedOwnedClient) {
      _client = http.Client();
      _closedOwnedClient = false;
    }
    try {
      var toProcess = List<Audiobook>.of(books);
      while (toProcess.isNotEmpty && !_cancelled) {
        for (final book in toProcess) {
          if (_cancelled) break;

          // Skip if the book already has a local cover.
          if (book.coverImagePath != null || book.coverImageBytes != null) {
            continue;
          }

          final status = await getStatus(book.path);
          if (status.enriched) continue;

          // Don't retry more than once per day.
          if (status.lastAttempted != null &&
              DateTime.now().difference(status.lastAttempted!).inHours < 24) {
            continue;
          }

          await _enrichBook(book);
        }
        toProcess = List<Audiobook>.of(_pendingBooks);
        _pendingBooks.clear();
      }
    } finally {
      _processing = false;
    }
  }

  /// Stop any in-progress enrichment queue, aborting any in-flight HTTP request.
  /// Also discards any books that were queued but not yet started.
  void cancel() {
    _cancelled = true;
    _pendingBooks.clear();
    _client.close();
    if (!_usingInjectedClient) {
      _closedOwnedClient = true;
    }
  }

  /// Release resources. Only needed if the singleton is torn down (e.g. tests).
  void dispose() {
    cancel();
    _controller.close();
    enrichingPaths.dispose();
    failedPaths.dispose();
  }

  Future<void> _enrichBook(Audiobook book) async {
    await _recordAttempt(book.path);
    _markEnriching(book.path);
    _log('Fetching cover for "${book.title}"');

    try {
      final coverPath =
          await _fetchCoverForTitle(book.title, author: book.author);
      if (coverPath != null) {
        await _recordSuccess(book.path, coverPath);
        _clearFailed(book.path);
        _controller.add((bookPath: book.path, coverPath: coverPath));
        _log('Cover saved for "${book.title}"');
      } else {
        _markFailed(book.path);
        _log('No cover found for "${book.title}"');
      }
    } on http.ClientException {
      // Client was closed by cancel() — exit silently.
    } catch (e) {
      _markFailed(book.path);
      _log('Error enriching "${book.title}": $e');
    } finally {
      _unmarkEnriching(book.path);
    }
  }

  Future<String?> _fetchCoverForTitle(String title, {String? author}) async {
    // Prefer an author-constrained query (better precision); fall back to
    // title-only when the author is unknown or the combined query misses.
    if (author != null && author.isNotEmpty) {
      final hit = await _searchOpenLibrary(title, author);
      if (hit != null) return hit;
      TelemetryService.logEvent('enrich_author_fallback',
          parameters: {'title': title});
    }
    return _searchOpenLibrary(title, null);
  }

  Future<String?> _searchOpenLibrary(String title, String? author) async {
    final encodedTitle = Uri.encodeComponent(title);
    final authorParam = (author == null || author.isEmpty)
        ? ''
        : '&author=${Uri.encodeComponent(author)}';
    final searchResp = await _client
        .get(Uri.parse(
            '$_openLibrarySearchUrl?title=$encodedTitle$authorParam&limit=1'))
        .timeout(const Duration(seconds: 10));

    if (searchResp.statusCode != 200) return null;

    final data = jsonDecode(searchResp.body) as Map<String, dynamic>;
    final docs = data['docs'] as List?;
    if (docs == null || docs.isEmpty) return null;

    final coverId = docs.first['cover_i'];
    if (coverId == null) return null;
    if (coverId is! num) {
      // Only a numeric Open Library cover id is meaningful. Anything else is
      // unexpected upstream data and must not reach a URL or a path.
      _log('Unexpected cover_i type: ${coverId.runtimeType}');
      return null;
    }

    return await _downloadCover(coverId.toInt().toString());
  }

  /// [coverId] is validated as a non-negative integer by the caller before it
  /// gets here, so it is safe to interpolate into a URL path and a filename.
  Future<String?> _downloadCover(String coverId) async {
    final coverResp = await _client
        .get(Uri.parse(
            '$_openLibraryCoverUrl/$coverId-L.jpg'))
        .timeout(const Duration(seconds: 15));

    if (!isValidCoverResponse(
      statusCode: coverResp.statusCode,
      contentType: coverResp.headers['content-type'],
      contentLength: coverResp.bodyBytes.length,
    )) {
      _log('Rejecting cover response: '
          'status=${coverResp.statusCode} '
          'type=${coverResp.headers['content-type']} '
          'bytes=${coverResp.bodyBytes.length}');
      return null;
    }

    final cacheDir = await getApplicationCacheDirectory();
    final coversDir = Directory('${cacheDir.path}/covers');
    await coversDir.create(recursive: true);

    final file = File('${coversDir.path}/$coverId.jpg');
    await file.writeAsBytes(coverResp.bodyBytes);
    return file.path;
  }

  Future<void> _recordAttempt(String bookPath) async {
    final db = await _database;
    await db.insert(
      'enrichment',
      {
        'book_path': bookPath,
        'enriched': 0,
        'last_attempted_date': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> _recordSuccess(String bookPath, String coverPath) async {
    final db = await _database;
    await db.update(
      'enrichment',
      {
        'enriched': 1,
        'cover_path': coverPath,
        'last_enriched_date': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'book_path = ?',
      whereArgs: [bookPath],
    );
  }
}

/// Maximum accepted cover-image size (bytes). Covers larger than this are
/// rejected to avoid disk bloat and catch mis-served pages.
const int maxCoverBytes = 10 * 1024 * 1024; // 10 MB

/// Minimum accepted cover-image size (bytes). Tiny responses are usually
/// placeholders or error pages.
const int minCoverBytes = 128;

/// Returns true if an HTTP response is a plausible image to save as a cover.
/// Checks status == 200, content-type starts with `image/`, and body size is
/// within [minCoverBytes]..[maxCoverBytes]. Pure function.
bool isValidCoverResponse({
  required int statusCode,
  required String? contentType,
  required int contentLength,
}) {
  if (statusCode != 200) return false;
  if (contentType == null) return false;
  if (!contentType.toLowerCase().startsWith('image/')) return false;
  if (contentLength < minCoverBytes) return false;
  if (contentLength > maxCoverBytes) return false;
  return true;
}
