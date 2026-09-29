import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/audiobook.dart';

/// Schedules the delayed deletion of a Drive book's local copies after it
/// finishes playing. If the user presses play again within the delay, the
/// scheduled delete is cancelled and the files are kept.
///
/// Collaborators are injected as closures so this class can be tested
/// without mocking the full services.
class DriveRemovalScheduler {
  DriveRemovalScheduler({
    required this.getBookStatus,
    required this.deleteFiles,
    required this.isRemoveWhenFinishedEnabled,
    this.delay = const Duration(minutes: 1),
  });

  /// Returns the current [BookStatus] for [bookPath]. Used to verify the
  /// book is still "finished" at fire time (the user may have restarted it).
  final Future<BookStatus> Function(String bookPath) getBookStatus;

  /// Deletes the local files for a Drive folder.
  final Future<void> Function(String folderId) deleteFiles;

  /// Reads the user preference — if false, we never schedule.
  final Future<bool> Function() isRemoveWhenFinishedEnabled;

  /// Delay between scheduling and the actual delete.
  final Duration delay;

  Timer? _timer;

  /// Bumped by every [cancel]. `scheduleForBook` captures it before its
  /// `await` and re-checks afterwards, so a cancel that lands while the
  /// preference lookup is in flight still wins.
  int _generation = 0;

  /// True while a scheduled delete is pending.
  bool get isPending => _timer != null;

  /// Queue a delete for [book]. No-op if:
  ///   * it isn't a Drive book,
  ///   * it has no Drive folder metadata,
  ///   * or the `removeWhenFinished` preference is disabled.
  /// Any previously-pending schedule is cancelled first.
  Future<void> scheduleForBook(Audiobook book) async {
    cancel();
    final generation = _generation;
    if (book.source != AudiobookSource.drive) return;
    final folderId = book.driveMetadata?.folderId;
    if (folderId == null) return;
    if (!await isRemoveWhenFinishedEnabled()) return;
    // The user pressed play while we were awaiting. Without this check the
    // resumed continuation installs a timer anyway — cancel() ran against a
    // still-null timer and was a no-op — and the files get deleted a minute
    // later while they are actively listening.
    if (generation != _generation) return;

    _timer = Timer(delay, () async {
      try {
        final status = await getBookStatus(book.path);
        if (status == BookStatus.finished) {
          await deleteFiles(folderId);
        }
      } catch (e) {
        // A failure here must not escape the callback's future (an unhandled
        // zone error). The `finally` still clears _timer, so without this the
        // book would look "cleaned up" when it was not.
        debugPrint('[Kowhai:DriveRemoval] scheduled delete failed: $e');
      } finally {
        _timer = null;
      }
    });
  }

  /// Cancel the pending delete (user pressed play again).
  void cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => cancel();
}
