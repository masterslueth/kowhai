import 'package:audio_service/audio_service.dart';
import '../models/audiobook.dart';

/// Owns the mapping between Kōwhai's internal state and the
/// `audio_service` notification streams (`playbackState` + `mediaItem`).
///
/// The broadcaster does NOT hold a reference to the handler itself — the
/// caller injects closures that read/write the underlying BehaviorSubjects.
/// This keeps it pure enough to unit-test.
class MediaStateBroadcaster {
  MediaStateBroadcaster({
    required this.getPlaybackState,
    required this.setPlaybackState,
    required this.setMediaItem,
  });

  final PlaybackState Function() getPlaybackState;
  final void Function(PlaybackState) setPlaybackState;
  final void Function(MediaItem) setMediaItem;

  int skipInterval = 30;

  MediaControl get _rewindControl => MediaControl(
        androidIcon: 'drawable/ic_replay',
        label: '-$skipInterval s',
        action: MediaAction.rewind,
      );

  MediaControl get _forwardControl => MediaControl(
        androidIcon: 'drawable/ic_forward',
        label: '+$skipInterval s',
        action: MediaAction.fastForward,
      );

  List<MediaControl> _buildControls(bool playing) => [
        _rewindControl,
        MediaControl.skipToPrevious,
        playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
        _forwardControl,
      ];

  /// Emit a PlaybackState sourced from the local just_audio player.
  void broadcastLocal({
    required bool playing,
    required AudioProcessingState processingState,
    required Duration position,
    required Duration bufferedPosition,
    required double speed,
    int? queueIndex,
  }) {
    setPlaybackState(getPlaybackState().copyWith(
      controls: _buildControls(playing),
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [1, 2, 3],
      processingState: processingState,
      playing: playing,
      updatePosition: position,
      bufferedPosition: bufferedPosition,
      speed: speed,
      queueIndex: queueIndex,
    ));
  }

  /// Emit a PlaybackState sourced from a Cast receiver status.
  void broadcastCast({
    required bool playing,
    required AudioProcessingState processingState,
    required Duration position,
    required double speed,
  }) {
    setPlaybackState(getPlaybackState().copyWith(
      controls: _buildControls(playing),
      systemActions: const {MediaAction.seek},
      androidCompactActionIndices: const [1, 2, 3],
      processingState: processingState,
      playing: playing,
      updatePosition: position,
      speed: speed,
    ));
  }

  /// Push a media item reflecting the current book + chapter.
  void updateMediaItem({
    required Audiobook book,
    required int chapterIndex,
    Duration? duration,
    Uri? artUri,
  }) {
    setMediaItem(MediaItem(
      id: book.path,
      title: book.title,
      artist: book.author ?? '',
      duration: duration,
      artUri: artUri,
      extras: {
        'chapterIndex': chapterIndex,
        'chapterCount': book.chapters.isNotEmpty
            ? book.chapters.length
            : book.audioFiles.length,
      },
    ));
  }
}

/// Maps just_audio's [ProcessingState] to audio_service's
/// [AudioProcessingState]. Pure.
AudioProcessingState mapLocalProcessingState(String justAudioStateName) {
  switch (justAudioStateName) {
    case 'idle':
      return AudioProcessingState.idle;
    case 'loading':
      return AudioProcessingState.loading;
    case 'buffering':
      return AudioProcessingState.buffering;
    case 'ready':
      return AudioProcessingState.ready;
    case 'completed':
      return AudioProcessingState.completed;
  }
  return AudioProcessingState.idle;
}

// ── Chapter navigation (pure) ─────────────────────────────────────────────────

/// Target position for skipToNext when the book has embedded chapters.
/// Returns null if we're on the last chapter (caller can no-op or seek
/// to end).
Duration? nextChapterStart({
  required Duration currentPosition,
  required List<Chapter> chapters,
  required int Function(Duration) chapterIndexAt,
}) {
  if (chapters.isEmpty) return null;
  final idx = chapterIndexAt(currentPosition);
  if (idx < chapters.length - 1) return chapters[idx + 1].start;
  return null;
}

/// Target position for skipToPrevious in a chaptered book:
///   * if we're > [restartThreshold] into the current chapter → start of it,
///   * else if there's a previous chapter → its start,
///   * else → Duration.zero.
Duration previousChapterTarget({
  required Duration currentPosition,
  required List<Chapter> chapters,
  required int Function(Duration) chapterIndexAt,
  Duration restartThreshold = const Duration(seconds: 5),
}) {
  if (chapters.isEmpty) return Duration.zero;
  final idx = chapterIndexAt(currentPosition);
  final chapterStart = chapters[idx].start;
  if (currentPosition - chapterStart > restartThreshold) {
    return chapterStart;
  }
  if (idx > 0) return chapters[idx - 1].start;
  return Duration.zero;
}

/// Clamped fast-forward position for a non-chaptered source.
///
/// A `null` [totalDuration] means "duration not known yet" (just_audio reports
/// null while idle or loading), NOT "the book is zero seconds long". Treating
/// the unknown case as zero made `target > max` true for any positive step and
/// returned `Duration.zero`, so a fast-forward issued before the duration
/// resolved seeked the book back to 0:00. With no upper bound to respect, the
/// target is returned unclamped.
Duration clampedForward(Duration current, Duration? totalDuration,
    Duration step) {
  final target = current + step;
  if (totalDuration == null) return target;
  return target > totalDuration ? totalDuration : target;
}

/// Clamped rewind position for a non-chaptered source.
Duration clampedRewind(Duration current, Duration step) {
  final target = current - step;
  return target < Duration.zero ? Duration.zero : target;
}
