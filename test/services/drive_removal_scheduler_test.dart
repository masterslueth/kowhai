import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kowhai/models/audiobook.dart';
import 'package:kowhai/services/drive_removal_scheduler.dart';

Audiobook _driveBook({
  String path = '/drive/book',
  String? folderId = 'folder-1',
}) =>
    Audiobook(
      title: 'Drive Book',
      path: path,
      audioFiles: const [],
      source: AudiobookSource.drive,
      driveMetadata: folderId == null
          ? null
          : DriveBookMeta(
              folderId: folderId,
              folderName: 'Drive Book',
              isShared: false,
              totalFileCount: 1,
            ),
    );

Audiobook _localBook({String path = '/local/book'}) =>
    Audiobook(title: 'Local', path: path, audioFiles: const []);

/// Builds a scheduler with lambda stubs. [onDelete] is called with the
/// folderId the scheduler tried to delete; unused by tests that just need
/// "nothing ran".
DriveRemovalScheduler _make({
  BookStatus statusAtFire = BookStatus.finished,
  bool removeWhenFinished = true,
  required List<String> deletedFolders,
  Duration delay = const Duration(minutes: 1),
}) =>
    DriveRemovalScheduler(
      getBookStatus: (_) async => statusAtFire,
      deleteFiles: (f) async => deletedFolders.add(f),
      isRemoveWhenFinishedEnabled: () async => removeWhenFinished,
      delay: delay,
    );

void main() {
  group('DriveRemovalScheduler.scheduleForBook', () {
    test('schedules delete for a Drive book with preference enabled', () {
      fakeAsync((async) {
        final deleted = <String>[];
        final s = _make(deletedFolders: deleted);
        s.scheduleForBook(_driveBook());
        async.flushMicrotasks();
        expect(s.isPending, isTrue);
        async.elapse(const Duration(minutes: 1));
        expect(deleted, ['folder-1']);
        expect(s.isPending, isFalse);
      });
    });

    test('does NOT schedule for a local book', () {
      fakeAsync((async) {
        final deleted = <String>[];
        final s = _make(deletedFolders: deleted);
        s.scheduleForBook(_localBook());
        async.flushMicrotasks();
        expect(s.isPending, isFalse);
        async.elapse(const Duration(minutes: 5));
        expect(deleted, isEmpty);
      });
    });

    test('does NOT schedule when folderId is null', () {
      fakeAsync((async) {
        final deleted = <String>[];
        final s = _make(deletedFolders: deleted);
        s.scheduleForBook(_driveBook(folderId: null));
        async.flushMicrotasks();
        expect(s.isPending, isFalse);
        async.elapse(const Duration(minutes: 5));
        expect(deleted, isEmpty);
      });
    });

    test('does NOT schedule when preference is disabled', () {
      fakeAsync((async) {
        final deleted = <String>[];
        final s = _make(
          deletedFolders: deleted,
          removeWhenFinished: false,
        );
        s.scheduleForBook(_driveBook());
        async.flushMicrotasks();
        expect(s.isPending, isFalse);
        async.elapse(const Duration(minutes: 5));
        expect(deleted, isEmpty);
      });
    });

    test('skips delete if the book is no longer finished at fire time', () {
      fakeAsync((async) {
        final deleted = <String>[];
        final s = _make(
          deletedFolders: deleted,
          statusAtFire: BookStatus.inProgress,
        );
        s.scheduleForBook(_driveBook());
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 1));
        expect(deleted, isEmpty);
        expect(s.isPending, isFalse);
      });
    });

    test('a second schedule replaces the first', () {
      fakeAsync((async) {
        final deleted = <String>[];
        final s = _make(deletedFolders: deleted);
        s.scheduleForBook(_driveBook(path: '/a', folderId: 'folder-a'));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        s.scheduleForBook(_driveBook(path: '/b', folderId: 'folder-b'));
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 1));
        // Only the second book's folder should be deleted.
        expect(deleted, ['folder-b']);
      });
    });
  });

  group('DriveRemovalScheduler.cancel', () {
    test('cancels a pending schedule', () {
      fakeAsync((async) {
        final deleted = <String>[];
        final s = _make(deletedFolders: deleted);
        s.scheduleForBook(_driveBook());
        async.flushMicrotasks();
        expect(s.isPending, isTrue);
        s.cancel();
        expect(s.isPending, isFalse);
        async.elapse(const Duration(minutes: 5));
        expect(deleted, isEmpty);
      });
    });

    test('is safe to call when nothing is pending', () {
      final s = _make(deletedFolders: []);
      s.cancel();
      s.cancel();
      expect(s.isPending, isFalse);
    });

    test('cancel during the preference lookup still wins', () {
      // Regression: cancel() used to run BEFORE the
      // isRemoveWhenFinishedEnabled() await, so a cancel landing during that
      // suspension cancelled a still-null timer and the resumed continuation
      // installed a fresh one — deleting files while the user was listening.
      fakeAsync((async) {
        final deleted = <String>[];
        final completer = Completer<bool>();
        final s = DriveRemovalScheduler(
          getBookStatus: (_) async => BookStatus.finished,
          deleteFiles: (f) async => deleted.add(f),
          isRemoveWhenFinishedEnabled: () => completer.future,
          delay: const Duration(minutes: 1),
        );

        unawaited(s.scheduleForBook(_driveBook()));
        async.flushMicrotasks();
        expect(s.isPending, isFalse, reason: 'timer not installed yet');

        // The user presses play: cancel lands while the lookup is in flight.
        s.cancel();
        expect(s.isPending, isFalse);

        // Now the preference lookup resolves and the continuation resumes.
        completer.complete(true);
        async.flushMicrotasks();

        expect(s.isPending, isFalse,
            reason: 'a superseded schedule must not install a timer');
        async.elapse(const Duration(minutes: 5));
        expect(deleted, isEmpty,
            reason: 'files must not be deleted after the user pressed play');
      });
    });

    test('a delete failure does not escape the timer callback', () {
      // Regression: the callback used `try/finally` with no `catch`, so a
      // throw from getBookStatus/deleteFiles became an unhandled async error
      // while the `finally` still cleared the timer — making a failed
      // cleanup look like a successful one.
      fakeAsync((async) {
        var deleteAttempts = 0;
        final s = DriveRemovalScheduler(
          getBookStatus: (_) async => throw StateError('db gone'),
          deleteFiles: (_) async => deleteAttempts++,
          isRemoveWhenFinishedEnabled: () async => true,
          delay: const Duration(minutes: 1),
        );
        s.scheduleForBook(_driveBook());
        async.flushMicrotasks();
        expect(s.isPending, isTrue);

        // An unhandled error here fails the test; completing cleanly is the
        // assertion.
        async.elapse(const Duration(minutes: 1));
        async.flushMicrotasks();

        expect(s.isPending, isFalse, reason: 'timer must still be cleared');
        expect(deleteAttempts, 0);
      });
    });
  });
}
