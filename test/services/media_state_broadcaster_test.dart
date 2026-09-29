import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kowhai/models/audiobook.dart';
import 'package:kowhai/services/media_state_broadcaster.dart';

Audiobook _book({
  String title = 'Book',
  String? author,
  List<String> audioFiles = const ['a.mp3'],
  List<Chapter> chapters = const [],
}) =>
    Audiobook(
      title: title,
      author: author,
      path: '/books/$title',
      audioFiles: audioFiles,
      chapters: chapters,
    );

void main() {
  group('MediaStateBroadcaster.broadcastLocal', () {
    test('emits a PlaybackState with skip-interval-labelled controls', () {
      PlaybackState? emitted;
      final b = MediaStateBroadcaster(
        getPlaybackState: () => PlaybackState(),
        setPlaybackState: (s) => emitted = s,
        setMediaItem: (_) {},
      );
      b.skipInterval = 15;
      b.broadcastLocal(
        playing: true,
        processingState: AudioProcessingState.ready,
        position: const Duration(seconds: 10),
        bufferedPosition: const Duration(seconds: 12),
        speed: 1.25,
      );
      expect(emitted, isNotNull);
      expect(emitted!.playing, isTrue);
      expect(emitted!.speed, 1.25);
      expect(emitted!.updatePosition, const Duration(seconds: 10));
      // Controls: [rewind, prev, pause, next, forward] — 5 items.
      expect(emitted!.controls.length, 5);
      expect(emitted!.controls.first.label, '-15 s');
      expect(emitted!.controls.last.label, '+15 s');
      // While playing we show the pause control in the middle slot.
      expect(emitted!.controls[2].action, MediaAction.pause);
    });

    test('uses play control when not playing', () {
      PlaybackState? emitted;
      final b = MediaStateBroadcaster(
        getPlaybackState: () => PlaybackState(),
        setPlaybackState: (s) => emitted = s,
        setMediaItem: (_) {},
      );
      b.broadcastLocal(
        playing: false,
        processingState: AudioProcessingState.ready,
        position: Duration.zero,
        bufferedPosition: Duration.zero,
        speed: 1.0,
      );
      expect(emitted!.controls[2].action, MediaAction.play);
    });
  });

  group('MediaStateBroadcaster.updateMediaItem', () {
    test('chapterCount uses chapters when present (M4B)', () {
      MediaItem? emitted;
      final b = MediaStateBroadcaster(
        getPlaybackState: () => PlaybackState(),
        setPlaybackState: (_) {},
        setMediaItem: (m) => emitted = m,
      );
      b.updateMediaItem(
        book: _book(chapters: const [
          Chapter(title: 'Ch1', start: Duration.zero),
          Chapter(title: 'Ch2', start: Duration(minutes: 10)),
          Chapter(title: 'Ch3', start: Duration(minutes: 20)),
        ]),
        chapterIndex: 1,
      );
      expect(emitted!.extras!['chapterCount'], 3);
      expect(emitted!.extras!['chapterIndex'], 1);
    });

    test('chapterCount falls back to audioFiles length for multi-file books',
        () {
      MediaItem? emitted;
      final b = MediaStateBroadcaster(
        getPlaybackState: () => PlaybackState(),
        setPlaybackState: (_) {},
        setMediaItem: (m) => emitted = m,
      );
      b.updateMediaItem(
        book: _book(audioFiles: const ['a.mp3', 'b.mp3', 'c.mp3']),
        chapterIndex: 2,
      );
      expect(emitted!.extras!['chapterCount'], 3);
    });

    test('empty author falls back to empty string', () {
      MediaItem? emitted;
      final b = MediaStateBroadcaster(
        getPlaybackState: () => PlaybackState(),
        setPlaybackState: (_) {},
        setMediaItem: (m) => emitted = m,
      );
      b.updateMediaItem(book: _book(author: null), chapterIndex: 0);
      expect(emitted!.artist, '');
    });
  });

  group('mapLocalProcessingState', () {
    test('known states map directly', () {
      expect(mapLocalProcessingState('idle'), AudioProcessingState.idle);
      expect(mapLocalProcessingState('loading'), AudioProcessingState.loading);
      expect(mapLocalProcessingState('buffering'),
          AudioProcessingState.buffering);
      expect(mapLocalProcessingState('ready'), AudioProcessingState.ready);
      expect(mapLocalProcessingState('completed'),
          AudioProcessingState.completed);
    });

    test('unknown states fall back to idle', () {
      expect(mapLocalProcessingState('weird'), AudioProcessingState.idle);
    });
  });

  group('nextChapterStart', () {
    final chapters = const [
      Chapter(title: 'Ch1', start: Duration.zero),
      Chapter(title: 'Ch2', start: Duration(minutes: 10)),
      Chapter(title: 'Ch3', start: Duration(minutes: 20)),
    ];

    test('returns next chapter start when one exists', () {
      final r = nextChapterStart(
        currentPosition: const Duration(minutes: 5),
        chapters: chapters,
        chapterIndexAt: (_) => 0,
      );
      expect(r, const Duration(minutes: 10));
    });

    test('returns null on the last chapter', () {
      final r = nextChapterStart(
        currentPosition: const Duration(minutes: 25),
        chapters: chapters,
        chapterIndexAt: (_) => 2,
      );
      expect(r, isNull);
    });

    test('returns null when there are no chapters', () {
      final r = nextChapterStart(
        currentPosition: const Duration(minutes: 5),
        chapters: const [],
        chapterIndexAt: (_) => 0,
      );
      expect(r, isNull);
    });
  });

  group('previousChapterTarget', () {
    final chapters = const [
      Chapter(title: 'Ch1', start: Duration.zero),
      Chapter(title: 'Ch2', start: Duration(minutes: 10)),
      Chapter(title: 'Ch3', start: Duration(minutes: 20)),
    ];

    test('past threshold → restart current chapter', () {
      final r = previousChapterTarget(
        currentPosition: const Duration(minutes: 15),
        chapters: chapters,
        chapterIndexAt: (_) => 1,
      );
      expect(r, const Duration(minutes: 10));
    });

    test('within threshold → jump to previous chapter', () {
      final r = previousChapterTarget(
        currentPosition: const Duration(minutes: 10, seconds: 3),
        chapters: chapters,
        chapterIndexAt: (_) => 1,
      );
      expect(r, Duration.zero);
    });

    test('within threshold on first chapter → Duration.zero', () {
      final r = previousChapterTarget(
        currentPosition: const Duration(seconds: 2),
        chapters: chapters,
        chapterIndexAt: (_) => 0,
      );
      expect(r, Duration.zero);
    });

    test('no chapters → Duration.zero', () {
      final r = previousChapterTarget(
        currentPosition: const Duration(minutes: 5),
        chapters: const [],
        chapterIndexAt: (_) => 0,
      );
      expect(r, Duration.zero);
    });

    test('custom threshold is respected', () {
      final r = previousChapterTarget(
        currentPosition: const Duration(minutes: 10, seconds: 3),
        chapters: chapters,
        chapterIndexAt: (_) => 1,
        restartThreshold: const Duration(seconds: 1),
      );
      // 3s > 1s threshold → restart current chapter, not previous.
      expect(r, const Duration(minutes: 10));
    });
  });

  group('clampedForward / clampedRewind', () {
    test('forward stops at total duration', () {
      expect(
        clampedForward(
          const Duration(minutes: 9),
          const Duration(minutes: 10),
          const Duration(minutes: 5),
        ),
        const Duration(minutes: 10),
      );
    });

    test('forward advances when room remains', () {
      expect(
        clampedForward(
          const Duration(minutes: 1),
          const Duration(minutes: 10),
          const Duration(seconds: 30),
        ),
        const Duration(minutes: 1, seconds: 30),
      );
    });

    test('forward with null duration advances instead of resetting to zero',
        () {
      // Regression: an unknown duration was treated as Duration.zero, so any
      // positive step clamped "backwards" and fast-forward rewound the book.
      expect(
        clampedForward(
          const Duration(hours: 1, minutes: 42),
          null,
          const Duration(seconds: 30),
        ),
        const Duration(hours: 1, minutes: 42, seconds: 30),
      );
      // Also covers the original zero-position case.
      expect(
        clampedForward(Duration.zero, null, const Duration(seconds: 5)),
        const Duration(seconds: 5),
      );
    });

    test('rewind clamps at zero', () {
      expect(
        clampedRewind(const Duration(seconds: 3), const Duration(seconds: 10)),
        Duration.zero,
      );
    });

    test('rewind subtracts when room remains', () {
      expect(
        clampedRewind(const Duration(minutes: 5), const Duration(seconds: 30)),
        const Duration(minutes: 4, seconds: 30),
      );
    });
  });
}
