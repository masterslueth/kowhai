import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/audiobook.dart';
import '../utils/safe_fs_name.dart';
import 'drive_book_repository.dart';
import 'drive_download_manager.dart';
import 'download_progress_tracker.dart';
import 'drive_service.dart';
import 'preferences_service.dart';
import 'scanner_service.dart';

class DriveLibraryService {
  final DriveBookRepository _repo;
  final DriveService _driveService;
  final DriveDownloadManager _downloadManager;
  final PreferencesService _prefs;
  final ScannerService _scanner;
  final DownloadProgressTracker _tracker;

  DriveLibraryService(
    this._repo,
    this._driveService,
    this._downloadManager,
    this._prefs,
    this._scanner,
    this._tracker,
  );

  /// Returns the staging directory for a Drive book — always in app storage.
  /// All files are downloaded here first, before promoteToLocal() moves them
  /// to the final library location.
  @visibleForTesting
  Future<String> stagingDir(String folderId) async {
    final docs = await getApplicationDocumentsDirectory();
    // Sanitised for the same reason as folderName in bookDir: this is a raw
    // path segment taken from a DB column, and drive_download_manager builds
    // download destinations from it too. Drive ids are server-generated, so
    // this is defence in depth rather than an active exposure.
    return '${docs.path}/drive_books/${safeFsName(folderId)}';
  }

  /// Returns the final local directory for a Drive book.
  /// If the user has a local library folder set, uses [folderName] within it
  /// so the book becomes part of their regular library. Falls back to the
  /// staging directory (app isolated storage) when no library folder is set.
  Future<String> bookDir(String folderId, {String? folderName}) async {
    if (folderName != null) {
      final localPath = await _prefs.getLibraryPath();
      if (localPath != null && localPath.isNotEmpty) {
        // Drive folder names are user-controlled — sanitise so a hostile name
        // (e.g. containing `/` or `..`) cannot escape the library root.
        // Separator style is kept as-is: ScannerService normalises both sides
        // of the exclusion comparison, so a forward-slash join still matches
        // the backslash paths Directory.list() reports on Windows.
        return '$localPath/${safeFsName(folderName)}';
      }
    }
    return stagingDir(folderId);
  }

  /// Returns the final download directories of all known Drive books.
  /// Used by the scanner to exclude Drive-managed folders from local scan.
  Future<Set<String>> driveBookDirs() async {
    final books = await _repo.getAllDriveBooks();
    final dirs = <String>{};
    for (final b in books) {
      dirs.add(await bookDir(b.folderId, folderName: b.folderName));
    }
    return dirs;
  }

  /// Loads all known Drive books from DB without any network calls.
  Future<List<Audiobook>> loadDriveBooks() async {
    final books = await _repo.getAllDriveBooks();
    final result = <Audiobook>[];
    for (final record in books) {
      final book = await _buildAudiobook(record);
      result.add(book);
    }
    return result;
  }

  /// Builds an [Audiobook] from a [DriveBookRecord] + its file records.
  Future<Audiobook> _buildAudiobook(DriveBookRecord record) async {
    final finalDir = await bookDir(record.folderId, folderName: record.folderName);
    final staging = await stagingDir(record.folderId);
    final files = await _repo.getFilesForBook(record.folderId);

    // audioFiles only contains paths for downloaded files
    final audioFiles = files
        .where((f) => f.downloadState == DriveDownloadState.done && f.localPath != null)
        .map((f) => f.localPath!)
        .toList();

    // Cover: check final dir first (post-promotion), then staging.
    // Background cover downloads target staging to avoid creating an empty
    // folder in the library for books that haven't been downloaded yet.
    String? coverPath;
    for (final checkDir in [finalDir, staging]) {
      final coverFile = File('$checkDir/cover.jpg');
      if (await coverFile.exists()) {
        coverPath = coverFile.path;
        break;
      }
    }
    if (coverPath == null && record.coverFileId != null) {
      _downloadManager
          .downloadCover(
            folderId: record.folderId,
            coverFileId: record.coverFileId!,
            destDir: staging,
          )
          .ignore();
    }

    final totalFiles = files.length;

    return Audiobook(
      title: record.folderName,
      path: finalDir,
      audioFiles: audioFiles,
      source: AudiobookSource.drive,
      driveMetadata: DriveBookMeta(
        folderId: record.folderId,
        folderName: record.folderName,
        isShared: record.isShared,
        totalFileCount: totalFiles,
      ),
      coverImagePath: coverPath,
    );
  }

  /// Re-scans Drive for the user's chosen root folder, diffs against stored
  /// records, and adds new books. Does not remove books whose Drive source is
  /// gone (keeps downloaded content accessible).
  Future<List<Audiobook>> rescanDrive({void Function(String)? onProgress}) async {
    final rootFolder = await _prefs.getDriveRootFolder();
    if (rootFolder == null) return await loadDriveBooks();

    final account = _driveService.currentAccount;
    if (account == null) return await loadDriveBooks();

    onProgress?.call('Scanning Drive folder…');
    final scans = await _driveService.scanRootFolder(
        rootFolder.id, rootFolder.isShared);

    for (int i = 0; i < scans.length; i++) {
      final scan = scans[i];
      onProgress?.call('Processing ${i + 1} of ${scans.length} books…');
      final existing = await _repo.getDriveBook(scan.folder.id);
      if (existing != null) continue; // already tracked

      // Stage new books in app storage. The directory is created lazily by
      // _downloadFile when the first byte is written, so no folder appears in
      // the library until promoteToLocal() moves the completed download.
      final dir = await stagingDir(scan.folder.id);

      // Exclude dot files from Drive (hidden/system files)
      final audioFiles = scan.audioFiles
          .where((f) => !f.name.startsWith('.'))
          .toList();

      // Book record and all of its file records land in one transaction, so a
      // cancellation part-way cannot leave a tracked book with a partial file
      // set that rescanDrive would then skip forever.
      final fileRecords = <DriveFileRecord>[];
      for (int i = 0; i < audioFiles.length; i++) {
        final f = audioFiles[i];
        fileRecords.add(DriveFileRecord(
          folderId: scan.folder.id,
          fileIndex: i,
          fileId: f.id,
          fileName: f.name,
          mimeType: f.mimeType,
          sizeBytes: f.sizeBytes,
          downloadState: DriveDownloadState.none,
          localPath: '$dir/${safeFsName(f.name)}',
        ));
      }
      await _repo.upsertDriveBookWithFiles(
        DriveBookRecord(
          folderId: scan.folder.id,
          folderName: scan.folder.name,
          rootFolderId: rootFolder.id,
          isShared: scan.folder.isShared,
          accountEmail: account.email,
          addedAt: DateTime.now().millisecondsSinceEpoch,
          coverFileId: scan.coverFile?.id,
          audioFileIds: audioFiles.map((f) => f.id).toList(),
        ),
        fileRecords,
      );
    }

    return await loadDriveBooks();
  }

  /// Removes all Drive books that have no downloaded files from the DB.
  /// Call on disconnect. Books with at least one downloaded file are kept.
  Future<void> removeUndownloadedBooks() async {
    final books = await _repo.getAllDriveBooks();
    for (final record in books) {
      final files = await _repo.getFilesForBook(record.folderId);
      final hasDownloaded = files.any((f) => f.downloadState == DriveDownloadState.done);
      if (!hasDownloaded) {
        await _repo.deleteDriveBook(record.folderId);
        // Release the tracker's per-book notifier too; nothing can be
        // listening any more because the book is leaving the library.
        _tracker.forget(record.folderId);
      }
    }
  }

  /// Downloads all files for a book.
  Future<void> startDownload(String folderId) async {
    await _downloadManager.enqueueAllFiles(folderId);
  }

  /// After a book is fully downloaded, moves its files from staging (app
  /// storage) to the final library folder (if one is configured), then
  /// re-scans the local directory via ScannerService to get embedded chapters,
  /// author, durations, etc. Returns the enriched Audiobook, or null if the
  /// scan fails.
  Future<Audiobook?> promoteToLocal(String folderId) async {
    final record = await _repo.getDriveBook(folderId);
    if (record == null) return null;

    final staging = await stagingDir(folderId);
    final finalDir = await bookDir(folderId, folderName: record.folderName);

    // Move downloaded audio files to finalDir if they aren't already there.
    // When staging == finalDir (no library folder configured) this is a no-op.
    // Files already in finalDir (e.g. re-promotion or pre-fix downloads) are
    // detected by the src == dest check and skipped.
    if (staging != finalDir) {
      await Directory(finalDir).create(recursive: true);
      final files = await _repo.getFilesForBook(folderId);
      for (final f in files) {
        if (f.downloadState != DriveDownloadState.done || f.localPath == null) continue;
        final destPath = '$finalDir/${safeFsName(f.fileName)}';
        if (f.localPath == destPath) continue;
        final srcFile = File(f.localPath!);
        final srcExists = await srcFile.exists();
        final destExists = await File(destPath).exists();

        if (!srcExists && destExists) {
          // Self-heal: the destination is already correct but the DB still
          // points at the old staging path. This is the state left behind by
          // the previous copy→delete→update ordering, which could be killed
          // between the delete and the update, permanently stranding the book
          // on a path that no longer exists.
          await _repo.updateFileLocalPath(folderId, f.fileIndex, destPath);
          continue;
        }
        if (!srcExists) continue;

        // Order matters: the DB is repointed BEFORE the staging copy is
        // removed. Killing the process after the update leaves a stray
        // duplicate in staging (harmless, and the scan ignores it); killing it
        // after a delete-first ordering left the DB pointing at a missing file
        // with no way back.
        await srcFile.copy(destPath);
        await _repo.updateFileLocalPath(folderId, f.fileIndex, destPath);
        await srcFile.delete();
      }
      // Move cover from staging to finalDir if it landed there.
      final stagingCover = File('$staging/cover.jpg');
      final finalCover = File('$finalDir/cover.jpg');
      if (await stagingCover.exists() && !await finalCover.exists()) {
        await stagingCover.copy(finalCover.path);
        await stagingCover.delete();
      }
    }

    // Download cover to finalDir if still missing
    final coverPath = '$finalDir/cover.jpg';
    if (record.coverFileId != null && !await File(coverPath).exists()) {
      await _downloadManager.downloadCover(
        folderId: folderId,
        coverFileId: record.coverFileId!,
        destDir: finalDir,
      );
    }

    // Re-scan the local directory
    final scanned = await _scanner.scanSingleBook(finalDir);
    if (scanned == null) return null;

    // Ensure cover is picked up even if scanner didn't find one
    String? finalCoverPath = scanned.coverImagePath;
    if (finalCoverPath == null) {
      final coverFile = File('$finalDir/cover.jpg');
      if (await coverFile.exists()) finalCoverPath = coverFile.path;
    }

    // Return the scanned book augmented with Drive metadata
    return Audiobook(
      title: scanned.title.isNotEmpty ? scanned.title : record.folderName,
      author: scanned.author,
      duration: scanned.duration,
      path: scanned.path,
      coverImagePath: finalCoverPath,
      coverImageBytes: scanned.coverImageBytes,
      audioFiles: scanned.audioFiles,
      chapterDurations: scanned.chapterDurations,
      chapters: scanned.chapters,
      chapterNames: scanned.chapterNames,
      isDrmLocked: scanned.isDrmLocked,
      source: AudiobookSource.drive,
      driveMetadata: DriveBookMeta(
        folderId: record.folderId,
        folderName: record.folderName,
        isShared: record.isShared,
        totalFileCount: (await _repo.getFilesForBook(folderId)).length,
      ),
      narrator: scanned.narrator,
      description: scanned.description,
      publisher: scanned.publisher,
      language: scanned.language,
      releaseDate: scanned.releaseDate,
    );
  }

  /// Deletes locally downloaded audio files for a Drive book and resets its
  /// download state to none. Cover art is preserved. The book record is kept.
  Future<void> undownloadBook(String folderId) async {
    final files = await _repo.getFilesForBook(folderId);
    await _deleteLocalFilesQuietly(files);
    await _repo.resetBookDownloads(folderId);
    await _tracker.reseed(folderId);
  }

  /// Returns total size in bytes for all files in a Drive book.
  Future<int> totalSizeBytes(String folderId) async {
    final files = await _repo.getFilesForBook(folderId);
    return files.fold<int>(0, (sum, f) => sum + f.sizeBytes);
  }

  /// Deletes all downloaded audio files for [folderId] from disk and resets
  /// their download state to [DriveDownloadState.none]. The DB record and
  /// metadata are preserved so the book remains in the library as finished.
  Future<void> deleteLocalFiles(String folderId) async {
    final files = await _repo.getFilesForBook(folderId);
    await _deleteLocalFilesQuietly(files);
    await _repo.reseedFolderStates(folderId);
    await _tracker.reseed(folderId);
  }

  /// Deletes each file, isolating per-file failures.
  ///
  /// A single `delete()` throwing (file locked, read-only volume) previously
  /// aborted the loop, leaving the already-deleted files still marked 'done'
  /// in the DB. `resetStaleDownloads` only rescues 'downloading' rows, so those
  /// files were never revisited and the library kept advertising audio files
  /// that no longer existed.
  Future<void> _deleteLocalFilesQuietly(List<DriveFileRecord> files) async {
    for (final f in files) {
      final path = f.localPath;
      if (path != null) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (e) {
          debugPrint('[Kowhai:Drive] could not delete $path: $e');
        }
      }
    }
  }
}
