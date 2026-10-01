import 'package:flutter_test/flutter_test.dart';
import 'package:kowhai/models/audiobook.dart';
import 'package:kowhai/services/position_service.dart';

void main() {
  group('PositionService status derivation', () {
    test('zero global position → notStarted', () {
      expect(
        PositionService.deriveStatusForTesting(0, 3600000),
        BookStatus.notStarted,
      );
    });

    test('negative global position → notStarted', () {
      expect(
        PositionService.deriveStatusForTesting(-100, 3600000),
        BookStatus.notStarted,
      );
    });

    test('in-progress mid-book → inProgress', () {
      expect(
        PositionService.deriveStatusForTesting(1800000, 3600000),
        BookStatus.inProgress,
      );
    });

    test('just inside 60s finished threshold → finished', () {
      // 3_600_000 - 59_999 = 3_540_001; within 60s of end
      expect(
        PositionService.deriveStatusForTesting(3540001, 3600000),
        BookStatus.finished,
      );
    });

    test('just outside 60s finished threshold → inProgress', () {
      // 3_600_000 - 60_001 = 3_539_999; outside the 60s window
      expect(
        PositionService.deriveStatusForTesting(3539999, 3600000),
        BookStatus.inProgress,
      );
    });

    test('a book shorter than the 60s allowance is not instantly finished', () {
      // Regression: the bound was `total - 60_000`, which for a 20s clip is
      // negative, so ANY progress at all reported the book as finished.
      expect(
        PositionService.deriveStatusForTesting(1000, 20000),
        BookStatus.inProgress,
      );
      expect(
        PositionService.deriveStatusForTesting(5000, 20000),
        BookStatus.inProgress,
      );
      // Past the midpoint, so finished is the correct answer.
      expect(
        PositionService.deriveStatusForTesting(19000, 20000),
        BookStatus.finished,
      );
    });

    test('allowance is capped at half the book for very short media', () {
      // 90s book: the 60s allowance exceeds half, so half (45s) is used.
      expect(
        PositionService.deriveStatusForTesting(44000, 90000),
        BookStatus.inProgress,
      );
      expect(
        PositionService.deriveStatusForTesting(46000, 90000),
        BookStatus.finished,
      );
      // A 5-minute book keeps the full 60s allowance (60s < half).
      expect(
        PositionService.deriveStatusForTesting(241000, 300000),
        BookStatus.finished,
      );
    });

    test('global >= total → finished', () {
      expect(
        PositionService.deriveStatusForTesting(3600000, 3600000),
        BookStatus.finished,
      );
      expect(
        PositionService.deriveStatusForTesting(3700000, 3600000),
        BookStatus.finished,
      );
    });

    test('totalMs == 0 with progress → inProgress (unknown duration)', () {
      expect(
        PositionService.deriveStatusForTesting(1000, 0),
        BookStatus.inProgress,
      );
    });
  });
}
