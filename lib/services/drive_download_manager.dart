import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'drive_book_repository.dart';
import 'drive_service.dart';
import '../utils/safe_fs_name.dart';

class DriveDownloadEvent {
  final String folderId;
  final int? fileIndex; // null = cover download
  final DriveDownloadState state;
  final double? progress; // 0.0–1.0, null if unknown
  final int? bytesDownloaded; // bytes received for current file
  final int? fileSizeBytes; // total size of current file

  const DriveDownloadEvent({
    required this.folderId,
    this.fileIndex,
    required this.state,
    this.progress,
    this.bytesDownloaded,
    this.fileSizeBytes,
  });
}

/// Rate-limits in-flight progress emissions AT SOURCE so UI listeners (and
/// the tracker) aren't flooded per TCP chunk. Terminal states bypass.
///
/// Emits when EITHER the minimum interval elapsed OR progress moved by at
/// least [minFraction]. Unknown totals fall back to byte-delta-only gating.
class ProgressThrottle {
  ProgressThrottle({
    this.minInterval = const Duration(milliseconds: 100),
    this.minFraction = 0.01,
    this.minBytesUnknownTotal = 64 * 1024,
    DateTime Function()? clock,
  }) : _now = clock ?? DateTime.now;

  final Duration minInterval;
  final double minFraction;
  final int minBytesUnknownTotal;
  final DateTime Function() _now;

  DateTime? _lastEmit;
  int _lastReceived = -1;

  /// Returns true if a progress update with [received]/[total] may emit now.
  bool shouldEmit(int received, int total) {
    if (_lastEmit == null || _lastReceived < 0) {
      _mark(received);
      return true;
    }
    final elapsed = _now().difference(_lastEmit!);
    final delta = received - _lastReceived;
    final allowed = total > 0
        ? elapsed >= minInterval ||
            (delta > 0 && delta / total >= minFraction)
        : elapsed >= minInterval || delta >= minBytesUnknownTotal;
    if (allowed) _mark(received);
    return allowed;
  }

  void _mark(int received) {
    _lastEmit = _now();
    _lastReceived = received;
  }
}

class DriveDownloadManager {
  final DriveBookRepository _repo;
  final DriveService _driveService;

  /// Delay before a failed job's retry. Injectable for tests.
  @visibleForTesting
  final Duration retryDelay;

  DriveDownloadManager(this._repo, this._driveService,
      {this.retryDelay = const Duration(seconds: 3)});

  final _controller = StreamController<DriveDownloadEvent>.broadcast();
  Stream<DriveDownloadEvent> get downloadEvents => _controller.stream;

  // Per-book download queues. Each book has at most one active download at a time.
  final Map<String, _BookQueue> _queues = {};
  // Limit total concurrent active downloads across all books.
  int _activeCount = 0;
  static const _maxConcurrent = 2;

  /// Re-enqueues any book that is not fully downloaded and shows evidence of
  /// an interrupted transfer — either a file in [DriveDownloadState.error] or
  /// one still flagged 'downloading' from a process that was killed without
  /// running its error handler. Called on app resume to recover downloads that
  /// were interrupted by background network suspension (iOS) or Android Doze.
  Future<void> resumeInterruptedDownloads() async {
    final books = await _repo.getAllDriveBooks();
    for (final book in books) {
      final files = await _repo.getFilesForBook(book.folderId);
      if (files.isEmpty) continue;
      final allDone = files.every((f) => f.downloadState == DriveDownloadState.done);
      if (allDone) continue;
      // A file left in 'downloading' has no live future to complete it if the
      // owning process is gone, and nothing re-seeds it (resetStaleDownloads
      // runs only at startup). Resetting to 'none' lets enqueueAllFiles pick
      // it up instead of leaving the book permanently mid-transfer.
      final stranded = files
          .where((f) => f.downloadState == DriveDownloadState.downloading)
          .toList();
      for (final f in stranded) {
        await _repo.updateFileState(
            book.folderId, f.fileIndex, DriveDownloadState.none);
      }
      final hasError = files.any((f) => f.downloadState == DriveDownloadState.error);
      if (hasError || stranded.isNotEmpty) {
        await enqueueAllFiles(book.folderId);
      }
    }
  }

  /// Download all files for [folderId] — used for M4B (single file) and initial
  /// multi-file download where we want the whole book.
  Future<void> enqueueAllFiles(String folderId) async {
    // Clear any stale pending jobs from a previous download attempt.
    _queues[folderId]?.pending.clear();

    final files = await _repo.getFilesForBook(folderId);
    // Include error-state files so retrying a failed download works.
    final toQueue = files
        .where((f) =>
            f.downloadState == DriveDownloadState.none ||
            f.downloadState == DriveDownloadState.error)
        .toList();
    // Reset error-state files back to none before re-queuing.
    for (final f in toQueue) {
      if (f.downloadState == DriveDownloadState.error) {
        await _repo.updateFileState(folderId, f.fileIndex, DriveDownloadState.none);
      }
      _enqueue(folderId, f);
    }
    _drain();
  }

  void _enqueue(String folderId, DriveFileRecord file) {
    final queue = _queues.putIfAbsent(folderId, () => _BookQueue(folderId));
    // Avoid duplicates
    if (queue.pending.any((j) => j.fileIndex == file.fileIndex)) return;
    queue.pending.add(_DownloadJob(
      folderId: folderId,
      fileIndex: file.fileIndex,
      fileId: file.fileId,
      fileName: file.fileName,
      localPath: file.localPath ?? '',
      sizeBytes: file.sizeBytes,
    ));
  }

  void _drain() {
    final snapshots = _queues.values.map((q) => DownloadQueueSnapshot(
          folderId: q.folderId,
          active: q.active,
          hasPending: q.pending.isNotEmpty,
        ));
    final toStart = selectQueuesToStart(
      queues: snapshots,
      activeCount: _activeCount,
      maxConcurrent: _maxConcurrent,
    );
    for (final folderId in toStart) {
      final queue = _queues[folderId]!;
      final job = queue.pending.removeAt(0);
      queue.active = true;
      _activeCount++;
      _runJob(queue, job);
    }
  }

  void _runJob(_BookQueue queue, _DownloadJob job) {
    _doDownload(job, queue).then((_) {
      queue.active = false;
      queue.activeClient = null;
      _activeCount--;
      _drain();
    }).catchError((Object e) {
      debugPrint('[Kowhai:Download] ${job.fileName} failed '
          '(${job.retriesLeft} retries left): $e');
      queue.active = false;
      queue.activeClient = null;
      _activeCount--;
      if (queue.cancelling) {
        // Cancellation in progress — don't retry, just drain remaining.
        queue.cancelling = false;
        _drain();
      } else if (job.retriesLeft > 0) {
        // Re-queue at the front with one fewer retry, after a short delay.
        queue.retryPending = true;
        Future.delayed(retryDelay, () {
          queue.retryPending = false;
          // A cancelDownload() during the delay window must win — never
          // resurrect a job the user cancelled.
          if (queue.cancelling) {
            queue.cancelling = false;
            _drain();
            return;
          }
          queue.pending.insert(0, job.withRetry());
          _drain();
        });
      } else {
        _drain();
      }
    });
  }

  /// Cancels all pending and active downloads for [folderId].
  Future<void> cancelDownload(String folderId) async {
    final queue = _queues[folderId];
    if (queue == null) return;
    queue.cancelling = true;
    queue.pending.clear();
    final client = queue.activeClient;
    if (client != null) {
      // Causes the active stream to throw; that job's error handler consumes
      // the cancelling flag once the abort is processed.
      client.close();
    } else if (!queue.retryPending) {
      // Nothing in flight and no retry scheduled — clear the flag now so a
      // later genuine failure on this queue still gets its retries.
      queue.cancelling = false;
    }
  }

  Future<void> _doDownload(_DownloadJob job, _BookQueue queue) async {
    await _repo.updateFileState(
        job.folderId, job.fileIndex, DriveDownloadState.downloading);
    _controller.add(DriveDownloadEvent(
      folderId: job.folderId,
      fileIndex: job.fileIndex,
      state: DriveDownloadState.downloading,
      progress: 0,
    ));

    try {
      final destPath = job.localPath.isNotEmpty
          ? job.localPath
          : await _defaultDestPath(job.folderId, job.fileName);

      await _downloadFile(
        fileId: job.fileId,
        destPath: destPath,
        onClientCreated: (client) => queue.activeClient = client,
        onProgress: (received, total) {
          _controller.add(DriveDownloadEvent(
            folderId: job.folderId,
            fileIndex: job.fileIndex,
            state: DriveDownloadState.downloading,
            progress: total > 0 ? received / total : null,
            bytesDownloaded: received,
            fileSizeBytes: job.sizeBytes,
          ));
        },
      );

      await _repo.updateFileState(
        job.folderId,
        job.fileIndex,
        DriveDownloadState.done,
        localPath: destPath,
      );
      _controller.add(DriveDownloadEvent(
        folderId: job.folderId,
        fileIndex: job.fileIndex,
        state: DriveDownloadState.done,
        progress: 1.0,
        fileSizeBytes: job.sizeBytes,
      ));
    } catch (_) {
      await _repo.updateFileState(
          job.folderId, job.fileIndex, DriveDownloadState.error);
      _controller.add(DriveDownloadEvent(
        folderId: job.folderId,
        fileIndex: job.fileIndex,
        state: DriveDownloadState.error,
      ));
      rethrow;
    }
  }

  /// Downloads a single Drive file to [destPath], streaming to avoid memory bloat.
  /// Retries once on 401 with a fresh token.
  Future<void> _downloadFile({
    required String fileId,
    required String destPath,
    void Function(int received, int total)? onProgress,
    void Function(http.Client client)? onClientCreated,
  }) async {
    final token = await _driveService.getAccessToken();
    if (token == null) throw Exception('Not signed in');

    Future<void> attempt(String t) async {
      final uri = Uri.parse(
          'https://www.googleapis.com/drive/v3/files/$fileId?alt=media');
      final request = http.Request('GET', uri)
        ..headers['Authorization'] = 'Bearer $t';
      final client = http.Client();
      onClientCreated?.call(client);
      try {
        final response = await client.send(request);
        if (response.statusCode == 401) {
          throw _AuthException();
        }
        if (response.statusCode != 200) {
          throw Exception('Drive download failed: ${response.statusCode}');
        }

        final file = File(destPath);
        await file.parent.create(recursive: true);
        final sink = file.openWrite();
        int received = 0;
        final total = response.contentLength ?? 0;
        final throttle = ProgressThrottle();

        try {
          await for (final chunk in response.stream
              .timeout(const Duration(seconds: 30))) {
            sink.add(chunk);
            received += chunk.length;
            if (throttle.shouldEmit(received, total)) {
              onProgress?.call(received, total);
            }
          }
          // Final exact count always reported (terminal, bypasses throttle).
          if (received != 0) onProgress?.call(received, total);
        } catch (_) {
          await sink.close();
          // Delete partial file so a retry starts fresh.
          if (await file.exists()) await file.delete();
          rethrow;
        }
        await sink.flush();
        await sink.close();
      } finally {
        client.close();
      }
    }

    try {
      await attempt(token);
    } on _AuthException {
      // Refresh and retry once
      final newToken = await _driveService.getAccessToken();
      if (newToken == null) rethrow;
      await attempt(newToken);
    }
  }

  /// Downloads the cover image for a book.
  Future<String?> downloadCover({
    required String folderId,
    required String coverFileId,
    required String destDir,
    String fileName = 'cover.jpg',
  }) async {
    final destPath = '$destDir/$fileName';
    try {
      await _downloadFile(fileId: coverFileId, destPath: destPath);
      _controller.add(DriveDownloadEvent(
        folderId: folderId,
        fileIndex: null,
        state: DriveDownloadState.done,
      ));
      return destPath;
    } catch (_) {
      return null;
    }
  }

  Future<String> _defaultDestPath(String folderId, String fileName) async {
    final dir = await getApplicationDocumentsDirectory();
    // Both segments are sanitised: fileName comes from Drive metadata
    // (user-controlled) and folderId is a raw path segment from the DB.
    return '${dir.path}/drive_books/${safeFsName(folderId)}/${safeFsName(fileName)}';
  }

  void dispose() {
    _controller.close();
  }
}

class _BookQueue {
  final String folderId;
  bool active = false;
  bool cancelling = false;
  bool retryPending = false; // a failed job's delayed retry is scheduled
  http.Client? activeClient;
  final List<_DownloadJob> pending = [];
  _BookQueue(this.folderId);
}

class _DownloadJob {
  final String folderId;
  final int fileIndex;
  final String fileId;
  final String fileName;
  final String localPath;
  final int sizeBytes;
  final int retriesLeft;

  _DownloadJob({
    required this.folderId,
    required this.fileIndex,
    required this.fileId,
    required this.fileName,
    required this.localPath,
    required this.sizeBytes,
    this.retriesLeft = 3,
  });

  _DownloadJob withRetry() => _DownloadJob(
        folderId: folderId,
        fileIndex: fileIndex,
        fileId: fileId,
        fileName: fileName,
        localPath: localPath,
        sizeBytes: sizeBytes,
        retriesLeft: retriesLeft - 1,
      );
}

class _AuthException implements Exception {}

/// Read-only view of a per-book download queue, used by [selectQueuesToStart].
class DownloadQueueSnapshot {
  final String folderId;
  final bool active;
  final bool hasPending;

  const DownloadQueueSnapshot({
    required this.folderId,
    required this.active,
    required this.hasPending,
  });
}

/// Picks which queues are ready to start their next job, respecting the global
/// concurrency limit and the rule that a single book never runs two downloads
/// at once. Pure function — no side effects.
///
/// Returns folderIds in iteration order, capped by remaining concurrency
/// (`maxConcurrent - activeCount`).
List<String> selectQueuesToStart({
  required Iterable<DownloadQueueSnapshot> queues,
  required int activeCount,
  required int maxConcurrent,
}) {
  final remaining = maxConcurrent - activeCount;
  if (remaining <= 0) return const [];
  final result = <String>[];
  for (final q in queues) {
    if (result.length >= remaining) break;
    if (q.active || !q.hasPending) continue;
    result.add(q.folderId);
  }
  return result;
}
