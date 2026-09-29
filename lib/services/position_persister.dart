import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/audiobook.dart';
import '../utils/formatters.dart';
import 'position_service.dart';

/// A snapshot of where playback currently is — chapter index + offset
/// within that chapter. Source-agnostic: can come from the local player or
/// from a Cast device.
typedef PositionSnapshot = ({int chapterIndex, Duration position});

/// Owns position persistence for the currently-loaded book:
///
/// * periodic save every [interval] while [startPeriodic] is active
/// * one-shot [save] on demand (used on pause / stop / completion)
///
/// Source-agnostic by design — the caller injects [readPosition] and
/// [getBook] closures so the same class works for local playback, Cast
/// playback, or any future source. [readPosition] returning null suppresses
/// the save: used while a book is being loaded, where sampling transitional
/// player state could persist one book's path with another's position.
class PositionPersister {
  PositionPersister({
    required this.positionService,
    required this.readPosition,
    required this.getBook,
    this.interval = const Duration(seconds: 5),
  });

  final PositionService positionService;

  /// Returns the current snapshot, or null when saving must be suppressed
  /// (e.g. mid-`loadBook`).
  final PositionSnapshot? Function() readPosition;
  final Audiobook? Function() getBook;
  final Duration interval;

  Timer? _timer;

  bool get isRunning => _timer != null;

  /// Begin saving on every [interval] tick. Idempotent — calling twice
  /// doesn't stack timers.
  void startPeriodic() {
    // save() is neither awaited nor catchError'd by the timer, so a DB write
    // failure (disk full, database closed during teardown) became an
    // UNHANDLED async error in the timer zone - fatal in tests and invisible
    // in release. Also skips a tick if the previous save is still in flight,
    // so slow writes cannot pile up overlapping saves.
    _timer ??= Timer.periodic(interval, (_) {
      if (_saveInFlight) return;
      _saveInFlight = true;
      save()
          .catchError((Object e) =>
              debugPrint('[Kowhai:Persister] periodic save failed: $e'))
          .whenComplete(() => _saveInFlight = false);
    });
  }

  bool _saveInFlight = false;

  /// Stop the periodic timer (if any). Does NOT perform a final save —
  /// callers typically want [save] right after.
  void stopPeriodic() {
    _timer?.cancel();
    _timer = null;
  }

  /// Save the current position right now. No-op if no book is loaded or the
  /// [readPosition] closure suppresses the sample.
  Future<void> save() async {
    final book = getBook();
    if (book == null) return;
    final snap = readPosition();
    if (snap == null) return;
    await saveSnapshot(book: book, snap: snap);
  }

  /// Persist an explicit snapshot for [book]. Single implementation of the
  /// global-position math shared by [save] and Cast teardown.
  Future<void> saveSnapshot({
    required Audiobook book,
    required PositionSnapshot snap,
  }) async {
    await positionService.savePosition(
      bookPath: book.path,
      chapterIndex: snap.chapterIndex,
      position: snap.position,
      globalPositionMs: calculateGlobalPosition(
        chapterIndex: snap.chapterIndex,
        chapterPosition: snap.position,
        chapterDurations: book.chapterDurations,
      ),
      totalDurationMs: book.duration?.inMilliseconds ?? 0,
    );
  }

  void dispose() => stopPeriodic();
}

