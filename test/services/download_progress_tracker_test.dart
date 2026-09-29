import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kowhai/services/download_progress_tracker.dart';
import 'package:kowhai/services/drive_book_repository.dart';
import 'package:kowhai/services/drive_download_manager.dart';
import 'package:kowhai/services/drive_service.dart';

// ---------------------------------------------------------------------------
// Fakes — the tracker only needs a DriveBookRepository for seeding and an
// event stream to attach to; both are trivially fakeable without mockito.
// ---------------------------------------------------------------------------

class _FakeRepo implements DriveBookRepository {
  _FakeRepo(this.filesByFolder);
  final Map<String, List<DriveFileRecord>> filesByFolder;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  Future<List<DriveFileRecord>> getFilesForBook(String folderId) async =>
      filesByFolder[folderId] ?? const [];

  @override
  Future<List<DriveBookRecord>> getAllDriveBooks() async => const [];
}

DriveFileRecord _file(int index, {required int size, String state = 'none'}) =>
    DriveFileRecord(
      folderId: 'f1',
      fileIndex: index,
      fileId: 'id-$index',
      fileName: 'file-$index.mp3',
      mimeType: 'audio/mpeg',
      sizeBytes: size,
      downloadState: _parse(state),
    );

// Map string states the same way the DB does.
DriveDownloadState _parse(String s) => switch (s) {
      'downloading' => DriveDownloadState.downloading,
      'done' => DriveDownloadState.done,
      'error' => DriveDownloadState.error,
      _ => DriveDownloadState.none,
    };

void main() {
  group('ProgressThrottle', () {
    test('first emission always passes', () {
      var t = 0;
      final throttle = ProgressThrottle(clock: () => DateTime.fromMillisecondsSinceEpoch(t));
      expect(throttle.shouldEmit(0, 1000), isTrue);
    });

    test('within interval and below fraction delta is suppressed', () {
      var t = 0;
      final throttle = ProgressThrottle(
        clock: () => DateTime.fromMillisecondsSinceEpoch(t),
      );
      throttle.shouldEmit(0, 1000);
      t = 50; // 50ms < 100ms interval; 5/1000 = 0.5% < 1% fraction floor
      expect(throttle.shouldEmit(5, 1000), isFalse);
      // Exactly 1% satisfies the >= minFraction rule.
      expect(throttle.shouldEmit(15, 1000), isTrue);
    });

    test('fraction delta bypasses interval', () {
      var t = 0;
      final throttle = ProgressThrottle(
        clock: () => DateTime.fromMillisecondsSinceEpoch(t),
      );
      throttle.shouldEmit(0, 1000);
      t = 10;
      expect(throttle.shouldEmit(20, 1000), isTrue); // 2% >= 1%
    });

    test('interval elapsed emits', () {
      var t = 0;
      final throttle = ProgressThrottle(
        clock: () => DateTime.fromMillisecondsSinceEpoch(t),
      );
      throttle.shouldEmit(0, 1000);
      t = 101;
      expect(throttle.shouldEmit(5, 1000), isTrue);
    });

    test('unknown total falls back to byte-delta gating', () {
      var t = 0;
      final throttle = ProgressThrottle(
        clock: () => DateTime.fromMillisecondsSinceEpoch(t),
      );
      throttle.shouldEmit(0, 0);
      t = 10;
      expect(throttle.shouldEmit(1024, 0), isFalse); // < 64KB
      t = 20;
      expect(throttle.shouldEmit(64 * 1024, 0), isTrue);
    });
  });

  group('DownloadProgressTracker', () {
    late StreamController<DriveDownloadEvent> events;

    setUp(() {
      events = StreamController<DriveDownloadEvent>.broadcast();
    });

    tearDown(() async {
      await events.close();
    });

    DownloadProgressTracker makeTracker(
        Map<String, List<DriveFileRecord>> files) {
      final repo = _FakeRepo(files);
      return DownloadProgressTracker(
        repository: repo,
        manager: DriveDownloadManager(repo, DriveService()),
      )..attach(events: events.stream);
    }

    DriveFileRecord done(int i, int size) => DriveFileRecord(
          folderId: 'f1',
          fileIndex: i,
          fileId: 'id-$i',
          fileName: 'f$i.mp3',
          mimeType: 'audio/mpeg',
          sizeBytes: size,
          downloadState: DriveDownloadState.done,
          localPath: '/x/f$i.mp3',
        );

    test('seed computes counts and bytes from repository', () async {
      final tracker = makeTracker({
        'f1': [_file(0, size: 100), _file(1, size: 300)],
      });
      await tracker.ensureSeeded('f1');
      final s = tracker.snapshotFor('f1')!;
      expect(s.totalCount, 2);
      expect(s.downloadedCount, 0);
      expect(s.totalBytes, 400);
      expect(s.overallProgress, 0);
    });

    test('events accumulate progress and fire completion once', () async {
      final tracker = makeTracker({
        'f1': [_file(0, size: 100, state: 'done'), _file(1, size: 100)],
      });
      var completions = 0;
      tracker.onBookCompleted = (_) async => completions++;
      await tracker.ensureSeeded('f1');
      expect(tracker.downloadingFolders.value.contains('f1'), isFalse);

      events.add(DriveDownloadEvent(
          folderId: 'f1',
          fileIndex: 1,
          state: DriveDownloadState.downloading,
          bytesDownloaded: 40));
      await Future<void>.delayed(Duration.zero);
      expect(tracker.snapshotFor('f1')!.overallProgress, closeTo(0.7, 1e-9));
      expect(tracker.downloadingFolders.value.contains('f1'), isTrue);

      events.add(DriveDownloadEvent(
          folderId: 'f1',
          fileIndex: 1,
          state: DriveDownloadState.done,
          fileSizeBytes: 60));
      await Future<void>.delayed(Duration.zero);

      final s = tracker.snapshotFor('f1')!;
      expect(s.isComplete, isTrue);
      expect(s.anyDownloading, isFalse);
      expect(completions, 1);
      expect(tracker.downloadingFolders.value.contains('f1'), isFalse);
    });

    test('error resets current-file bytes but keeps completed work', () async {
      final tracker = makeTracker({
        'f1': [done(0, 100), _file(1, size: 100)],
      });
      await tracker.ensureSeeded('f1');

      events.add(DriveDownloadEvent(
          folderId: 'f1',
          fileIndex: 1,
          state: DriveDownloadState.downloading,
          bytesDownloaded: 90));
      await Future<void>.delayed(Duration.zero);
      events.add(DriveDownloadEvent(
          folderId: 'f1',
          fileIndex: 1,
          state: DriveDownloadState.error));
      await Future<void>.delayed(Duration.zero);

      final s = tracker.snapshotFor('f1')!;
      expect(s.doneBytes, 100);
      expect(s.currentFileBytes, 0);
      expect(s.lastEventError, isTrue);
      expect(s.isComplete, isFalse);
    });

    test('an error clears anyDownloading so the spinner does not stick',
        () async {
      // Regression: the error branch left anyDownloading at the value set by
      // the preceding 'downloading' event, and nothing re-seeds on that path,
      // so the folder stayed in downloadingFolders indefinitely and the UI
      // showed a live progress indicator for a terminally failed download.
      final tracker = makeTracker({
        'f1': [_file(0, size: 100), _file(1, size: 100)],
      });
      await tracker.ensureSeeded('f1');

      events.add(DriveDownloadEvent(
          folderId: 'f1',
          fileIndex: 1,
          state: DriveDownloadState.downloading,
          bytesDownloaded: 90));
      await Future<void>.delayed(Duration.zero);
      expect(tracker.snapshotFor('f1')!.anyDownloading, isTrue);
      expect(tracker.downloadingFolders.value.contains('f1'), isTrue);

      events.add(DriveDownloadEvent(
          folderId: 'f1', fileIndex: 1, state: DriveDownloadState.error));
      await Future<void>.delayed(Duration.zero);

      expect(tracker.snapshotFor('f1')!.anyDownloading, isFalse);
      expect(tracker.downloadingFolders.value.contains('f1'), isFalse);
    });

    test('a duplicate done event for the same file is not double-counted',
        () async {
      // Regression: done incremented unconditionally per event, so a
      // duplicate could push downloadedCount past totalCount and latch
      // isComplete permanently true.
      final tracker = makeTracker({
        'f1': [_file(0, size: 100), _file(1, size: 100)],
      });
      var completions = 0;
      tracker.onBookCompleted = (_) async => completions++;
      await tracker.ensureSeeded('f1');

      for (var i = 0; i < 3; i++) {
        events.add(DriveDownloadEvent(
            folderId: 'f1',
            fileIndex: 1,
            state: DriveDownloadState.done,
            fileSizeBytes: 100));
        await Future<void>.delayed(Duration.zero);
      }

      final s = tracker.snapshotFor('f1')!;
      expect(s.downloadedCount, 1, reason: 'only one file actually finished');
      expect(s.doneBytes, 100);
      expect(s.isComplete, isFalse);
      expect(completions, 0);
    });

    test('forget releases tracker state for a removed book', () async {
      final tracker = makeTracker({
        'f1': [_file(0, size: 100, state: 'downloading')],
      });
      await tracker.ensureSeeded('f1');
      final notifier = tracker.listenableFor('f1');
      expect(tracker.downloadingFolders.value.contains('f1'), isTrue);

      tracker.forget('f1');

      expect(tracker.snapshotFor('f1'), isNull);
      expect(tracker.downloadingFolders.value.contains('f1'), isFalse);
      // A fresh notifier is created on next request; the old one is disposed.
      expect(identical(tracker.listenableFor('f1'), notifier), isFalse);
    });

    test('cover-only events do not move book progress', () async {
      final tracker = makeTracker({
        'f1': [_file(0, size: 100)],
      });
      await tracker.ensureSeeded('f1');

      events.add(DriveDownloadEvent(
          folderId: 'f1', fileIndex: null, state: DriveDownloadState.done));
      await Future<void>.delayed(Duration.zero);

      final s = tracker.snapshotFor('f1')!;
      expect(s.downloadedCount, 0);
      expect(s.isComplete, isFalse);
    });

    test('reseed reloads from repository after external mutation', () async {
      final files = [
        _file(0, size: 100, state: 'done'),
        _file(1, size: 100),
      ];
      final repoMap = {'f1': files};
      final tracker = makeTracker(repoMap);
      await tracker.ensureSeeded('f1');

      // Simulate undownload mutating rows behind the tracker's back.
      repoMap['f1'] = [_file(0, size: 100), _file(1, size: 100)];
      await tracker.reseed('f1');

      final s = tracker.snapshotFor('f1')!;
      expect(s.downloadedCount, 0);
      expect(s.doneBytes, 0);
    });
  });
}
