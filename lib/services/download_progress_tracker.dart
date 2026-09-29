import 'dart:async';

import 'package:flutter/foundation.dart';

import '../locator.dart';
import 'drive_book_repository.dart';
import 'drive_download_manager.dart';

/// Immutable snapshot of a Drive book's aggregate download state.
///
/// One snapshot per folderId, owned by [DownloadProgressTracker]. UI surfaces
/// render from this instead of each maintaining their own byte-counting state
/// machine (previously duplicated in four places).
@immutable
class BookDownloadProgress {
  final String folderId;
  final int downloadedCount;
  final int totalCount;
  final int doneBytes;
  final int totalBytes;
  final int currentFileBytes;
  final bool anyDownloading;
  final bool lastEventError;

  const BookDownloadProgress({
    required this.folderId,
    this.downloadedCount = 0,
    this.totalCount = 0,
    this.doneBytes = 0,
    this.totalBytes = 0,
    this.currentFileBytes = 0,
    this.anyDownloading = false,
    this.lastEventError = false,
    this.completedFileIndices = const {},
    this.inFlightFileIndices = const {},
  });

  /// File indices already counted as done, so a duplicate `done` event for the
  /// same file cannot inflate the counters.
  final Set<int> completedFileIndices;

  /// File indices with a download currently in flight. Lets `anyDownloading`
  /// be recomputed exactly when one finishes or fails, instead of being left
  /// at whatever the last `downloading` event set it to.
  final Set<int> inFlightFileIndices;

  /// 0.0-1.0 aggregate byte progress; 0 when total size unknown.
  double get overallProgress {
    if (totalBytes <= 0) return 0;
    return ((doneBytes + currentFileBytes) / totalBytes).clamp(0.0, 1.0);
  }

  bool get isComplete => totalCount > 0 && downloadedCount >= totalCount;

  BookDownloadProgress copyWith({
    int? downloadedCount,
    int? totalCount,
    int? doneBytes,
    int? totalBytes,
    int? currentFileBytes,
    bool? anyDownloading,
    bool? lastEventError,
    Set<int>? completedFileIndices,
    Set<int>? inFlightFileIndices,
  }) =>
      BookDownloadProgress(
        folderId: folderId,
        downloadedCount: downloadedCount ?? this.downloadedCount,
        totalCount: totalCount ?? this.totalCount,
        doneBytes: doneBytes ?? this.doneBytes,
        totalBytes: totalBytes ?? this.totalBytes,
        currentFileBytes: currentFileBytes ?? this.currentFileBytes,
        anyDownloading: anyDownloading ?? this.anyDownloading,
        lastEventError: lastEventError ?? this.lastEventError,
        completedFileIndices:
            completedFileIndices ?? this.completedFileIndices,
        inFlightFileIndices: inFlightFileIndices ?? this.inFlightFileIndices,
      );
}

/// A [ChangeNotifier]+[ValueListenable] pair for ONE folder's progress.
/// The tracker updates [value]; listeners rebuild.
class FolderProgressNotifier extends ChangeNotifier
    implements ValueListenable<BookDownloadProgress?> {
  BookDownloadProgress? _value;
  @override
  BookDownloadProgress? get value => _value;

  void _set(BookDownloadProgress? next) {
    if (identical(_value, next)) return;
    final old = _value;
    _value = next;
    if (old != null && next != null && old == next) return;
    notifyListeners();
  }
}

/// Owns aggregate download-progress state for all known Drive books.
///
/// Design (architect-verdicted, prd-44 F0):
/// * seeded lazily from the repository ([ensureSeeded]) and reseeded
///   explicitly by [DriveLibraryService] after undownload / deleteLocalFiles /
///   promoteToLocal ([reseed]), and wholesale after startup recovery
///   ([reseedAll]);
/// * ONE subscription to the manager's event stream ([attach]) applies
///   deltas to per-folder snapshots — UI never counts bytes itself;
/// * fires [onBookCompleted] once per idle→complete transition so callers can
///   promote a finished download exactly once;
/// * exposes [downloadingFolders] for coarse "which books are busy" queries
///   (library list tiles) without a second raw stream subscription.
class DownloadProgressTracker {
  DownloadProgressTracker({
    DriveBookRepository? repository,
    DriveDownloadManager? manager,
  })  : _repo = repository ?? locator<DriveBookRepository>(),
        _manager = manager ?? locator<DriveDownloadManager>();

  final DriveBookRepository _repo;
  final DriveDownloadManager _manager;

  final Map<String, BookDownloadProgress> _snapshots = {};
  final Map<String, FolderProgressNotifier> _notifiers = {};
  StreamSubscription<DriveDownloadEvent>? _sub;
  final Set<String> _seeding = {};

  /// Fired ONCE when a book transitions to fully-downloaded. Wire this to
  /// promotion logic (DriveLibraryService.promoteToLocal).
  Future<void> Function(String folderId)? onBookCompleted;

  /// Fired when a cover-only download completes (fileIndex == null).
  Future<void> Function(String folderId)? onCoverCompleted;

  /// ValueListenable over the set of folderIds with in-flight downloads.
  final ValueNotifier<Set<String>> downloadingFolders =
      ValueNotifier<Set<String>>(const {});

  /// Begins listening to download events. Defaults to the manager's stream;
  /// tests may inject their own. Subsequent calls are no-ops.
  void attach({Stream<DriveDownloadEvent>? events}) {
    _sub ??= (events ?? _manager.downloadEvents).listen(_onEvent);
  }

  /// Per-folder listenable for granular widget rebuilds. Created on demand.
  FolderProgressNotifier listenableFor(String folderId) =>
      _notifiers.putIfAbsent(folderId, FolderProgressNotifier.new);

  /// Drops all tracker state for [folderId] and disposes its notifier.
  ///
  /// Notifiers are created on demand by [listenableFor] and otherwise only
  /// released in [dispose], so a book's notifier (and its listener
  /// registrations) outlived the book itself for the life of the process.
  /// Only call this once the book is gone from the library — disposing a
  /// notifier a mounted widget is still listening to would throw.
  void forget(String folderId) {
    _notifiers.remove(folderId)?.dispose();
    _snapshots.remove(folderId);
    _seeding.remove(folderId);
    if (downloadingFolders.value.contains(folderId)) {
      downloadingFolders.value = {...downloadingFolders.value}..remove(folderId);
    }
  }

  BookDownloadProgress? snapshotFor(String folderId) => _snapshots[folderId];

  /// Lazily seeds [folderId] from the repository if not yet tracked.
  /// Idempotent; concurrent calls coalesce.
  Future<void> ensureSeeded(String folderId) async {
    if (_snapshots.containsKey(folderId)) return;
    if (_seeding.contains(folderId)) return;
    _seeding.add(folderId);
    try {
      await _seedFromRepo(folderId);
    } finally {
      _seeding.remove(folderId);
    }
  }

  /// Force-reloads [folderId]'s snapshot from the repository. Call after any
  /// operation that mutates file rows outside the download pipeline
  /// (undownload, deleteLocalFiles, promoteToLocal).
  Future<void> reseed(String folderId) async {
    await _seedFromRepo(folderId);
    _emit(folderId); // reflect reset immediately even with no new events
  }

  /// Reseed every known book — used after startup stale-download recovery.
  Future<void> reseedAll() async {
    final records = await _repo.getAllDriveBooks();
    for (final r in records) {
      await _seedFromRepo(r.folderId);
      _emit(r.folderId);
    }
  }

  Future<void> _seedFromRepo(String folderId) async {
    final files = await _repo.getFilesForBook(folderId);
    final done = files
        .where((f) => f.downloadState == DriveDownloadState.done)
        .toList(growable: false);
    final inFlight = files
        .where((f) => f.downloadState == DriveDownloadState.downloading)
        .map((f) => f.fileIndex)
        .toSet();
    _snapshots[folderId] = BookDownloadProgress(
      folderId: folderId,
      downloadedCount: done.length,
      totalCount: files.length,
      doneBytes: done.fold<int>(0, (s, f) => s + f.sizeBytes),
      totalBytes: files.fold<int>(0, (s, f) => s + f.sizeBytes),
      completedFileIndices: {for (final f in done) f.fileIndex},
      inFlightFileIndices: inFlight,
      anyDownloading: inFlight.isNotEmpty,
    );
    _syncDownloadingSet(folderId);
  }

  void _onEvent(DriveDownloadEvent e) {
    if (e.fileIndex == null) {
      // Cover-only event: notify observers on completion, ignore otherwise.
      if (e.state == DriveDownloadState.done) {
        final cb = onCoverCompleted;
        if (cb != null) cb(e.folderId);
      }
      return;
    }
    final s = _snapshots[e.folderId];
    var next = s ?? BookDownloadProgress(folderId: e.folderId);
    // Non-null: the cover-only path above already returned when it was null.
    final fileIndex = e.fileIndex!;

    switch (e.state) {
      case DriveDownloadState.downloading:
        final inFlight = {...next.inFlightFileIndices, fileIndex};
        next = next.copyWith(
          currentFileBytes: e.bytesDownloaded ?? 0,
          inFlightFileIndices: inFlight,
          anyDownloading: inFlight.isNotEmpty,
          lastEventError: false,
        );
        break;
      case DriveDownloadState.done:
        final wasComplete = next.isComplete;
        // Guard against double-counting: a duplicate `done` for a fileIndex
        // already recorded (re-download after a reset, or a book re-queued
        // with an index already done) used to increment unconditionally, which
        // could push downloadedCount past totalCount and latch isComplete
        // permanently true - firing onBookCompleted against a
        // half-downloaded book.
        if (next.completedFileIndices.contains(fileIndex)) {
          _storeAndEmit(e.folderId, next);
          return;
        }
        final inFlight = {...next.inFlightFileIndices}..remove(fileIndex);
        next = next.copyWith(
          downloadedCount: next.downloadedCount + 1,
          completedFileIndices: {...next.completedFileIndices, fileIndex},
          doneBytes: next.doneBytes + (e.fileSizeBytes ?? 0),
          currentFileBytes: 0,
          inFlightFileIndices: inFlight,
          anyDownloading: next.downloadedCount + 1 < next.totalCount &&
              inFlight.isNotEmpty,
          lastEventError: false,
        );
        _storeAndEmit(e.folderId, next);
        if (!wasComplete && next.isComplete) {
          final cb = onBookCompleted;
          if (cb != null) cb(e.folderId);
        }
        return;
      case DriveDownloadState.error:
        // anyDownloading is recomputed from the in-flight set rather than left
        // at the value the preceding 'downloading' event set. It previously
        // stuck at true, so _syncDownloadingSet kept the folder in
        // downloadingFolders forever and the UI showed a live spinner for a
        // terminally failed download - nothing re-seeds on this path.
        final inFlight = {...next.inFlightFileIndices}..remove(fileIndex);
        next = next.copyWith(
          currentFileBytes: 0,
          inFlightFileIndices: inFlight,
          anyDownloading: inFlight.isNotEmpty,
          lastEventError: true,
        );
        break;
      case DriveDownloadState.none:
        break;
    }
    _storeAndEmit(e.folderId, next);
  }

  void _storeAndEmit(String folderId, BookDownloadProgress next) {
    _snapshots[folderId] = next;
    _emit(folderId);
  }

  void _emit(String folderId) {
    final s = _snapshots[folderId];
    if (s == null) return;
    _notifiers[folderId]?._set(s);
    _syncDownloadingSet(folderId);
  }

  void _syncDownloadingSet(String folderId) {
    final s = _snapshots[folderId];
    if (s == null) return;
    final current = downloadingFolders.value;
    final has = current.contains(folderId);
    if (s.anyDownloading && !has) {
      downloadingFolders.value = {...current, folderId};
    } else if (!s.anyDownloading && has) {
      downloadingFolders.value = {...current}..remove(folderId);
    }
  }

  void dispose() {
    _sub?.cancel();
    // Nulled so a later attach() does not silently no-op on a cancelled
    // (non-null) subscription, which left the tracker deaf to events with no
    // error anywhere — progress simply stopped updating.
    _sub = null;
    for (final n in _notifiers.values) {
      n.dispose();
    }
    _notifiers.clear();
    downloadingFolders.dispose();
  }
}
