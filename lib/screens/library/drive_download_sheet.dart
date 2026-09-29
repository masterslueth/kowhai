import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

import '../../locator.dart';
import '../../models/audiobook.dart';
import '../../services/drive_download_manager.dart';
import '../../services/download_progress_tracker.dart';
import '../../services/drive_library_service.dart';
import '../../utils/formatters.dart';

/// Shows a bottom sheet prompting the user to download a Drive book.
///
/// Fetches [DriveLibraryService.totalSizeBytes] regardless of connectivity so
/// the formatted size appears in both the message and the Download button.
///
/// The optional [connectivityOverride] parameter is used by tests to inject a
/// known connectivity state without hitting the real network stack.
///
/// Returns when the sheet is dismissed — the modal future is returned, not
/// fire-and-forget. The sibling [showDriveDownloadProgressSheet] already had
/// that contract; returning early here meant every `await
/// showDriveDownloadSheet(...)` completed while the sheet was still open.
Future<bool?> showDriveDownloadSheet(
  BuildContext context,
  Audiobook book, {
  List<ConnectivityResult>? connectivityOverride,
}) async {
  final folderId = book.driveMetadata?.folderId;
  if (folderId == null) return null;

  final connectivity =
      connectivityOverride ?? await Connectivity().checkConnectivity();
  final isWifi = connectivity.contains(ConnectivityResult.wifi) ||
      connectivity.contains(ConnectivityResult.ethernet);

  // Always fetch the size so both prompts can show it.
  final sizeBytes =
      await locator<DriveLibraryService>().totalSizeBytes(folderId);

  if (!context.mounted) return null;

  return showModalBottomSheet<bool>(
    context: context,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            book.title,
            style: Theme.of(ctx).textTheme.titleMedium,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 8),
          Text(
            isWifi
                ? 'This book is ${formatBytes(sizeBytes)}. Download it to start listening.'
                : 'You\'re on mobile data. This book is ${formatBytes(sizeBytes)}. Download anyway?',
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                icon: const Icon(Icons.download_rounded),
                label: Text('Download (${formatBytes(sizeBytes)})'),
                onPressed: () {
                  Navigator.pop(ctx);
                  locator<DriveLibraryService>().startDownload(folderId);
                },
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

/// Shows a bottom sheet for a Drive book that is currently downloading.
/// Displays live progress from the shared [DownloadProgressTracker] and
/// offers a "Cancel download" action.
///
/// Returns `true` if the user cancelled the download, `false` / `null`
/// otherwise (sheet dismissed without action).
Future<bool?> showDriveDownloadProgressSheet(
  BuildContext context,
  Audiobook book,
) async {
  final folderId = book.driveMetadata?.folderId;
  if (folderId == null) return null;
  final tracker = locator<DownloadProgressTracker>();
  await tracker.ensureSeeded(folderId);

  if (!context.mounted) return null;

  return showModalBottomSheet<bool>(
    context: context,
    builder: (ctx) => _DownloadProgressSheet(
      book: book,
      folderId: folderId,
    ),
  );
}

class _DownloadProgressSheet extends StatefulWidget {
  final Audiobook book;
  final String folderId;

  const _DownloadProgressSheet({
    required this.book,
    required this.folderId,
  });

  @override
  State<_DownloadProgressSheet> createState() => _DownloadProgressSheetState();
}

class _DownloadProgressSheetState extends State<_DownloadProgressSheet> {
  late final FolderProgressNotifier _notifier;

  /// Latched once the sheet has asked to close. The tracker re-emits after
  /// the first completion (onBookCompleted → _refreshDriveBook → promoteToLocal
  /// → reseed → notifyListeners), and the sheet stays `mounted` for the whole
  /// ~250 ms route exit animation — so without this a second emission ran
  /// `Navigator.pop` again and popped the route BENEATH the sheet, ejecting
  /// the user out of the library.
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _notifier = locator<DownloadProgressTracker>().listenableFor(widget.folderId)
      ..addListener(_onChange);
  }

  void _onChange() {
    if (!mounted) return;
    final p = _notifier.value;
    if (p != null && p.isComplete) {
      if (_closing) return;
      _closing = true;
      Navigator.pop(context, false);
      return;
    }
    setState(() {});
  }

  @override
  void dispose() {
    _notifier.removeListener(_onChange);
    super.dispose();
  }

  Future<void> _cancelDownload() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel download?'),
        content: Text(
          'The download will be stopped and any partially downloaded '
          'files for "${widget.book.title}" will be deleted.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep downloading'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Cancel download',
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await locator<DriveDownloadManager>().cancelDownload(widget.folderId);
    await locator<DriveLibraryService>().undownloadBook(widget.folderId);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snap = _notifier.value ??
        const BookDownloadProgress(folderId: '');
    final progress = snap.overallProgress;
    final pct = (progress * 100).toStringAsFixed(0);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.book.title,
            style: theme.textTheme.titleMedium,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: progress > 0 ? progress : null,
                    minHeight: 6,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '$pct%',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Downloading - ${formatBytes((snap.doneBytes + snap.currentFileBytes).clamp(0, snap.totalBytes))} '
            'of ${formatBytes(snap.totalBytes)}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Dismiss'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  side: BorderSide(
                    color: theme.colorScheme.error.withValues(alpha: 0.5),
                  ),
                ),
                icon: const Icon(Icons.cancel_outlined),
                label: const Text('Cancel download'),
                onPressed: _cancelDownload,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
