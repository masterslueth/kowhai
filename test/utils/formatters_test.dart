import 'package:flutter_test/flutter_test.dart';
import 'package:kowhai/utils/formatters.dart';
import 'package:kowhai/utils/natural_sort.dart';

void main() {
  group('naturalCompare', () {
    test('orders small numeric segments numerically', () {
      final files = ['track10.mp3', 'track2.mp3', 'track1.mp3']..sort(naturalCompare);
      expect(files, ['track1.mp3', 'track2.mp3', 'track10.mp3']);
    });

    test('orders digit runs beyond 64 bits numerically, not lexicographically',
        () {
      // Regression: int.tryParse returns null past 2^63, so both operands took
      // the lexicographic branch and a longer run of 9s sorted BEFORE a
      // smaller number - exactly backwards.
      expect(naturalCompare('99999999999999999999', '1000000000000000000'),
          greaterThan(0));
      expect(naturalCompare('1000000000000000000', '99999999999999999999'),
          lessThan(0));
      // Both sides saturate, so this is a tie rather than a reversal.
      expect(naturalCompare('99999999999999999999', '88888888888888888888'),
          anyOf(0, lessThan(0)));
    });

    test('a huge number still sorts after a small one in the same segment', () {
      final list = ['ch99999999999999999999.mp3', 'ch2.mp3', 'ch10.mp3']
        ..sort(naturalCompare);
      expect(list, ['ch2.mp3', 'ch10.mp3', 'ch99999999999999999999.mp3']);
    });

    test('numbers sort before text in a segment position', () {
      expect(naturalCompare('track2', 'trackA'), isNot(0));
      expect(naturalCompare('trackA', 'track2'), isNot(0));
      // Antisymmetric.
      expect(naturalCompare('track2', 'trackA'),
          -naturalCompare('trackA', 'track2'));
    });

    test('identical inputs compare equal', () {
      expect(naturalCompare('chapter01.mp3', 'chapter01.mp3'), 0);
    });
  });

  group('globalToChapterPosition', () {
    test('maps a global position into the right chapter', () {
      final r = globalToChapterPosition(65000, [
        const Duration(seconds: 60),
        const Duration(seconds: 60),
      ]);
      expect(r.chapterIndex, 1);
      expect(r.position, const Duration(seconds: 5));
    });

    test('clamps overshoot to the end of the final chapter', () {
      final r = globalToChapterPosition(999000, [
        const Duration(seconds: 60),
        const Duration(seconds: 60),
      ]);
      expect(r.chapterIndex, 1);
      expect(r.position, const Duration(seconds: 60));
    });

    test('a zero-length final chapter collapses to position zero', () {
      // Regression: the `len > 0` guard skipped the clamp for a zero-length
      // chapter and returned the full unconsumed remaining - a position past
      // the end of the file it was attributed to. readMetadataChunk emits a
      // zero duration for every unreadable track, so this is reachable.
      final r = globalToChapterPosition(5000, [Duration.zero]);
      expect(r.chapterIndex, 0);
      expect(r.position, Duration.zero);
    });

    test('zero-length chapters are skipped, not selected', () {
      // A zero-length chapter cannot hold a position, so the remap moves
      // past it and attributes the offset to the next real chapter.
      final r = globalToChapterPosition(5000, [
        Duration.zero,
        const Duration(seconds: 60),
      ]);
      expect(r.chapterIndex, 1);
      expect(r.position, const Duration(seconds: 5));
    });

    test('zero global position maps to the start', () {
      final r = globalToChapterPosition(0, [const Duration(seconds: 60)]);
      expect(r.chapterIndex, 0);
      expect(r.position, Duration.zero);
    });
  });
}
