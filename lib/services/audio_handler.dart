import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/audiobook.dart';
import '../utils/safe_fs_name.dart';
import 'cast_controller.dart';
import 'drive_library_service.dart';
import 'drive_removal_scheduler.dart';
import 'media_state_broadcaster.dart' as msb;
import 'position_persister.dart' as pp;
import 'position_service.dart';
import 'preferences_service.dart';
import '../locator.dart';

class KowhaiHandler extends BaseAudioHandler {
  final AudioPlayer _player;
  Audiobook? _book;
  Uri? _artUri;
  late final pp.PositionPersister _persister;
  late final DriveRemovalScheduler _driveRemoval;
  late final msb.MediaStateBroadcaster _broadcaster;
  DateTime? _lastPausedAt;
  int? _lastMediaItemChapter;
  Duration? _lastMediaItemDuration;
  bool _autoRewind = true;

  /// True while a book is being loaded. The persister's [pp.PositionPersister.readPosition]
  /// closure consults this to suppress saves that would sample transitional
  /// player state mid-swap.
  bool _loading = false;

  /// Serialises concurrent loadBook calls (e.g. double-tap on two cards) so
  /// their bodies can't interleave.
  Future<void> _loadQueue = Future.value();

  AudioPlayer get player => _player;
  Audiobook? get currentBook => _book;

  /// Direct access to the persister for tests (e.g. asserting that periodic
  /// saves are suppressed mid-load).
  @visibleForTesting
  pp.PositionPersister get persister => _persister;

  // ── Cast state ──────────────────────────────────────────────────────────────

  late final CastController _cast;
  bool get isCasting => _cast.isCasting;
  Stream<bool> get castingStream => _cast.castingStream;

  /// Snapshot of the current playback position, from Cast or local player.
  Duration get effectivePosition =>
      isCasting ? _cast.position : _player.position;

  /// Effective position stream — emits local or Cast position depending on mode.
  final _effectivePositionController = StreamController<Duration>.broadcast();
  Stream<Duration> get effectivePositionStream =>
      _effectivePositionController.stream;

  /// Effective duration — updated when media loads locally or on Cast.
  final _effectiveDurationController = StreamController<Duration?>.broadcast();
  Stream<Duration?> get effectiveDurationStream =>
      _effectiveDurationController.stream;

  /// User-facing playback error message. `null` while healthy.
  ///
  /// Fires whenever `just_audio` reports an unrecoverable playback error
  /// (missing file, codec issue, …) or [loadBook] throws. The PlayerScreen
  /// listens to this to disable controls and surface a retry snackbar.
  final _errorController = StreamController<String?>.broadcast();
  Stream<String?> get errorStream => _errorController.stream;
  String? _lastError;
  String? get lastError => _lastError;

  /// [player] and [cast] are test seams — production callers use the
  /// parameterless constructor, which builds the real implementations.
  KowhaiHandler({
    @visibleForTesting AudioPlayer? player,
    @visibleForTesting CastController? cast,
  }) : _player = player ?? AudioPlayer() {
    _persister = pp.PositionPersister(
      positionService: locator<PositionService>(),
      getBook: () => _book,
      readPosition: () {
        if (_loading) return null; // mid-load state is not persistable
        return (
          chapterIndex: _player.currentIndex ?? 0,
          position: isCasting ? _cast.position : _player.position,
        );
      },
    );

    _driveRemoval = DriveRemovalScheduler(
      getBookStatus: (p) => locator<PositionService>().getBookStatus(p),
      deleteFiles: (f) => locator<DriveLibraryService>().deleteLocalFiles(f),
      isRemoveWhenFinishedEnabled: () =>
          locator<PreferencesService>().getRemoveWhenFinished(),
    );

    _broadcaster = msb.MediaStateBroadcaster(
      getPlaybackState: () => playbackState.value,
      setPlaybackState: playbackState.add,
      setMediaItem: mediaItem.add,
    );

    _cast = cast ??
        CastController(
          localPlayer: _player,
          persister: _persister,
          getBook: () => _book,
          onEffectivePosition: (p) => _effectivePositionController.add(p),
          onEffectiveDuration: (d) => _effectiveDurationController.add(d),
          onStatusChanged: _onCastStatusChanged,
        );

    final prefs = locator<PreferencesService>();
    prefs.getSkipInterval().then((s) => _broadcaster.skipInterval = s);
    prefs.getAutoRewind().then((v) => _autoRewind = v);

    _player.playbackEventStream.listen(
      _broadcastState,
      onError: (Object e) {
        debugPrint('[Kowhai:Error] playback error: $e');
        _reportError(_humanizePlayerError(e));
      },
    );

    // NOTE: just_audio's playingStream emits its CURRENT value on subscribe,
    // so this listener fires once with `false` during construction. Using
    // `??=` there seeded _lastPausedAt with the app-start time, and nothing
    // cleared it until a real play. The first play() after that measured
    // "paused" against app start, so browsing the library for 30 minutes and
    // then hitting play rewound the book by the full browse time without the
    // user ever having paused it. The seed is therefore skipped, and the value
    // is only set by the explicit pause() below.
    _player.playingStream.listen((playing) {
      if (playing) {
        _lastPausedAt = null;
      }
    });
    _player.currentIndexStream.listen(
      (index) {
        _broadcastState(null);
      },
      onError: (error, stackTrace) {
        debugPrint('[Kowhai:Player] Index stream error: $error');
      },
    );

    // Forward local streams to effective streams when not casting.
    _player.positionStream.listen((pos) {
      if (!isCasting) _effectivePositionController.add(pos);
    });
    _player.durationStream.listen((dur) {
      if (!isCasting) _effectiveDurationController.add(dur);
    });

    // Start/stop periodic save as playback state changes.
    _player.playingStream.listen((playing) {
      if (isCasting) return; // Cast save is handled separately.
      if (playing) {
        _persister.startPeriodic();
      } else {
        _persister.stopPeriodic();
        _persister.save(); // immediate save on pause
      }
    });

    // Handle playback completion (end of last file / M4B).
    _player.processingStateStream.listen((state) {
      if (state == ProcessingState.completed) {
        _persister.save();
        _onPlaybackCompleted();
      }
    });

    // Listen for Cast session changes.
    _cast.listenForSessions();
  }

  // ── Cast status → notification state ─────────────────────────────────────

  /// Invoked by [CastController] whenever the receiver reports a new status.
  /// Translates it into the platform notification state + media item.
  void _onCastStatusChanged(GoggleCastMediaStatus status) {
    final mapped = mapCastPlayerState(status.playerState);
    _broadcaster.broadcastCast(
      playing: mapped.playing,
      processingState: mapped.processingState,
      position: _cast.position,
      speed: status.playbackRate.toDouble(),
    );
    final dur = status.mediaInformation?.duration;
    if (dur != null) _effectiveDurationController.add(dur);
    _publishMediaItem();
  }

  // ── Completion handling ────────────────────────────────────────────────────

  Future<void> _onPlaybackCompleted() async {
    final book = _book;
    if (book == null) return;
    await locator<PositionService>()
        .updateBookStatus(book.path, BookStatus.finished);
    await _driveRemoval.scheduleForBook(book);
  }

  // ── Loading ────────────────────────────────────────────────────────────────

  /// Loads [book], restoring its saved position. Concurrent calls are
  /// serialised; switching books while casting tears the cast session down
  /// FIRST (while the old book's sources are still loaded) so the teardown
  /// seek-back lands on the correct audio.
  Future<void> loadBook(Audiobook book) {
    final op = _loadQueue.then((_) => _doLoadBook(book));
    // Keep the chain alive when a load fails — the next caller shouldn't
    // inherit this one's error.
    _loadQueue = op.catchError((_, __) {});
    return op;
  }

  Future<void> _doLoadBook(Audiobook book) async {
    if (_book?.path == book.path) return; // already loaded — resume in place

    // Switching books while casting: stop the cast BEFORE touching local
    // sources. CastController.stop() seeks the local player to the receiver's
    // last position — that seek is only meaningful while the casted book's
    // sources are still loaded. Best-effort: a failed teardown must not block
    // the new load.
    if (isCasting) {
      try {
        await _cast.stop();
      } catch (e) {
        debugPrint('[Kowhai:Player] cast teardown before load failed: $e');
      }
    }

    _loading = true;
    try {
      // Resolve artwork URI for the notification.
      Uri? artUri;
      if (book.coverImagePath != null) {
        artUri = Uri.file(book.coverImagePath!);
      } else if (book.coverImageBytes != null) {
        try {
          final tmp = await getTemporaryDirectory();
          // Refreshed on every load: the previous `if (!exists)` guard meant a
          // book whose embedded art changed kept serving the stale JPEG for
          // the life of the install. The name combines the sanitised basename
          // with a hash so two books with the same title in different folders
          // cannot collide on `hashCode` alone.
          final stem = p.basenameWithoutExtension(book.path);
          final f = File(
              '${tmp.path}/kowhai_cover_${safeFsName(stem)}_${book.path.hashCode.toUnsigned(32)}.jpg');
          await f.writeAsBytes(book.coverImageBytes!, flush: true);
          artUri = f.uri;
        } catch (_) {}
      }

      // Repair legacy rows that only carry a global position (restored from
      // old backups) before reading them — self-heals at the point of harm.
      final positionService = locator<PositionService>();
      try {
        await positionService.repairFromGlobal(book);
      } catch (e) {
        debugPrint('[Kowhai:Player] position repair skipped: $e');
      }

      final saved = await positionService.getPosition(book.path);

      final sources =
          book.audioFiles.map((p) => AudioSource.uri(Uri.file(p))).toList();
      await _player.setAudioSources(
        sources,
        initialIndex: saved?.chapterIndex ?? 0,
        initialPosition: saved?.position,
      );

      // Load succeeded — only now does the new book become current. On
      // failure the previous book stays current (no null limbo).
      _book = book;
      _artUri = artUri;
      _clearError();
      _publishMediaItem();

      // Re-cast the freshly loaded book if the session survived.
      if (_cast.isSessionConnected) await _cast.start();
    } on Exception catch (e) {
      _reportError(_humanizePlayerError(e));
      rethrow;
    } finally {
      _loading = false;
    }
  }

  @visibleForTesting
  static Duration getRewindOffset(Duration pausedDuration) {
    if (pausedDuration >= const Duration(hours: 24)) {
      return const Duration(seconds: 30);
    } else if (pausedDuration >= const Duration(hours: 1)) {
      return const Duration(seconds: 15);
    } else if (pausedDuration >= const Duration(minutes: 5)) {
      return const Duration(seconds: 10);
    }
    return Duration.zero;
  }

  // ── Playback controls ──────────────────────────────────────────────────────

  @override
  Future<void> play() async {
    // Cancel any pending removal — user is resuming/restarting.
    _driveRemoval.cancel();

    // If the book was finished and the user explicitly plays again, reset to inProgress.
    if (_book != null) {
      final status = await locator<PositionService>().getBookStatus(_book!.path);
      if (status == BookStatus.finished) {
        await locator<PositionService>()
            .updateBookStatus(_book!.path, BookStatus.inProgress);
      }
    }

    if (_autoRewind && _lastPausedAt != null) {
      final pausedDuration = DateTime.now().difference(_lastPausedAt!);
      final rewindAmount = getRewindOffset(pausedDuration);
      if (rewindAmount > Duration.zero) {
        final currentPos = isCasting ? _cast.position : _player.position;
        var newPos = currentPos - rewindAmount;
        if (newPos < Duration.zero) newPos = Duration.zero;
        await seek(newPos);
      }
    }
    _lastPausedAt = null;

    if (isCasting) {
      await _cast.play();
    } else {
      await _player.play();
    }
  }

  @override
  Future<void> pause() async {
    _lastPausedAt = DateTime.now();
    if (isCasting) {
      await _cast.pause();
      await _persister.save(); // awaited: a silent failure loses progress
    } else {
      await _player.pause();
    }
  }

  @override
  Future<void> seek(Duration position) async {
    if (isCasting) {
      await _cast.seekAbsolute(position);
    } else {
      await _player.seek(position);
    }
  }

  @override
  Future<void> skipToNext() async {
    final book = _book;
    final chapters = book?.chapters ?? const [];
    final pos = isCasting ? _cast.position : _player.position;
    final target = msb.nextChapterStart(
      currentPosition: pos,
      chapters: chapters,
      chapterIndexAt: book?.chapterIndexAt ?? (_) => 0,
    );

    if (target != null) {
      await seek(target);
      return;
    }
    if (isCasting) {
      await _cast.queueNext();
      return;
    }
    final idx = _player.currentIndex ?? 0;
    if (idx < _player.sequence.length - 1) await _player.seekToNext();
  }

  @override
  Future<void> skipToPrevious() async {
    final book = _book;
    final chapters = book?.chapters ?? const [];
    final pos = isCasting ? _cast.position : _player.position;

    if (chapters.isNotEmpty) {
      await seek(msb.previousChapterTarget(
        currentPosition: pos,
        chapters: chapters,
        chapterIndexAt: book!.chapterIndexAt,
      ));
      return;
    }
    if (isCasting) {
      await _cast.queuePrev();
      return;
    }
    if (_player.position > const Duration(seconds: 5)) {
      await _player.seek(Duration.zero);
    } else {
      final idx = _player.currentIndex ?? 0;
      if (idx > 0) {
        await _player.seekToPrevious();
      } else {
        await _player.seek(Duration.zero);
      }
    }
  }

  @override
  Future<void> fastForward() async {
    final interval = Duration(seconds: _broadcaster.skipInterval);
    if (isCasting) {
      await _cast.seekRelative(interval);
      return;
    }
    await _player.seek(
        msb.clampedForward(_player.position, _player.duration, interval));
  }

  @override
  Future<void> rewind() async {
    final interval = Duration(seconds: _broadcaster.skipInterval);
    if (isCasting) {
      await _cast.seekRelative(-interval);
      return;
    }
    await _player.seek(msb.clampedRewind(_player.position, interval));
  }

  @override
  Future<void> setSpeed(double speed) async {
    if (isCasting) {
      await _cast.setSpeed(speed);
    }
    // Always set local speed too so it's remembered.
    await _player.setSpeed(speed);
  }

  @override
  Future<void> stop() async {
    // Exactly one save on either path: while casting, CastController.stop()
    // performs the final snapshot save (from the receiver position cache) and
    // tears the session + server down; otherwise the local persister saves.
    if (isCasting) {
      await _cast.stop();
    } else {
      await _persister.save();
    }
    await _player.stop();
    return super.stop();
  }

  // ── State broadcasting ─────────────────────────────────────────────────────

  void updateSkipInterval(int seconds) {
    _broadcaster.skipInterval = seconds;
    _broadcastState(null);
  }

  void updateAutoRewind(bool value) {
    _autoRewind = value;
  }

  void _broadcastState(PlaybackEvent? event) {
    if (isCasting) return; // Cast status drives the broadcast when casting.
    // If we have an unresolved error, surface it in the processing state so
    // the UI can disable controls until the user retries.
    final state = _lastError != null
        ? AudioProcessingState.error
        : msb.mapLocalProcessingState(_player.processingState.name);
    _broadcaster.broadcastLocal(
      playing: _player.playing,
      processingState: state,
      position: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _player.currentIndex,
    );
    _publishMediaItemIfChanged();
  }

  // ── Error reporting ────────────────────────────────────────────────────────

  void _reportError(String message) {
    _lastError = message;
    _errorController.add(message);
    _broadcastState(null);
  }

  void _clearError() {
    if (_lastError == null) return;
    _lastError = null;
    _errorController.add(null);
  }

  /// Reload the current book from disk. Used by the Retry action in the UI.
  /// No-op if no book is loaded.
  Future<void> retry() async {
    final book = _book;
    if (book == null) return;
    _clearError();
    // Force reload even if path matches the stale in-memory book.
    _book = null;
    await loadBook(book);
  }

  /// Map a raw player error / exception to a concise, user-facing line.
  /// Keeps the original `toString()` for telemetry but trims it for display.
  @visibleForTesting
  static String humanizePlayerError(Object e) => _humanizePlayerError(e);

  static String _humanizePlayerError(Object e) {
    final raw = e.toString();
    final low = raw.toLowerCase();
    if (low.contains('source') && low.contains('not')) {
      return "Audio file couldn't be opened. It may have moved or been deleted.";
    }
    if (low.contains('permission')) {
      return 'Permission denied reading the audio file.';
    }
    if (low.contains('format') || low.contains('codec')) {
      return 'This file uses an unsupported audio format.';
    }
    if (low.contains('network') || low.contains('socket') ||
        low.contains('host')) {
      return 'Network problem while loading audio.';
    }
    return 'Playback error. Tap retry to try again.';
  }

  void _publishMediaItem() {
    final book = _book;
    if (book == null) return;
    _lastMediaItemChapter = _player.currentIndex ?? 0;
    _lastMediaItemDuration = _player.duration;
    _broadcaster.updateMediaItem(
      book: book,
      chapterIndex: _player.currentIndex ?? 0,
      duration: _player.duration,
      artUri: _artUri,
    );
  }

  /// Republishes the MediaItem only when something it actually displays has
  /// changed.
  ///
  /// `_broadcastState` is the handler for `playbackEventStream`, which fires
  /// on every position update (several times a second). Unconditionally
  /// calling `mediaItem.add(...)` there allocated a fresh MediaItem and
  /// serialised it across the platform channel to the Android media session
  /// that many times, even though the item only varies by chapter, duration
  /// and artwork.
  void _publishMediaItemIfChanged() {
    if (_book == null) return;
    final chapter = _player.currentIndex ?? 0;
    final duration = _player.duration;
    if (chapter == _lastMediaItemChapter &&
        duration == _lastMediaItemDuration) {
      return;
    }
    _publishMediaItem();
  }
}
