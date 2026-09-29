import 'package:flutter/material.dart';

import '../locator.dart';
import '../models/audiobook.dart';
import '../services/download_progress_tracker.dart';

/// Wraps a book cover with Drive-specific overlays driven by the shared
/// [DownloadProgressTracker]:
/// - Grey tint + progress when downloading
/// - Download badge when not (fully) downloaded
enum _OverlayState { notDownloaded, downloading, partial, done }

class DriveDownloadOverlay extends StatefulWidget {
  final Audiobook book;
  final Widget child;
  final double iconSize;
  final double indicatorSize;

  const DriveDownloadOverlay({
    super.key,
    required this.book,
    required this.child,
    this.iconSize = 40,
    this.indicatorSize = 40,
  });

  @override
  State<DriveDownloadOverlay> createState() => _DriveDownloadOverlayState();
}

class _DriveDownloadOverlayState extends State<DriveDownloadOverlay> {
  late final DownloadProgressTracker _tracker;
  FolderProgressNotifier? _notifier;

  @override
  void initState() {
    super.initState();
    _tracker = locator<DownloadProgressTracker>();
    _bind();
  }

  void _bind() {
    _notifier?.removeListener(_onChange);
    final folderId = widget.book.driveMetadata?.folderId;
    if (folderId == null) {
      _notifier = null;
      return;
    }
    // Lazy DB seed on first ask; survives cold-start ordering.
    _tracker.ensureSeeded(folderId);
    _notifier = _tracker.listenableFor(folderId)..addListener(_onChange);
  }

  // listenableFor returns a PROCESS-LIFETIME notifier shared by every overlay
  // for the same folder, and this widget is instantiated inside
  // GridView.builder / ListView.separated items — so hundreds of States
  // attach and detach on it during ordinary scrolling. A download event
  // landing mid-teardown would otherwise call setState on a defunct State.
  void _onChange() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void didUpdateWidget(DriveDownloadOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.book.driveMetadata?.folderId !=
        widget.book.driveMetadata?.folderId) {
      _bind();
    }
  }

  @override
  void dispose() {
    _notifier?.removeListener(_onChange);
    super.dispose();
  }

  _OverlayState _stateFor(BookDownloadProgress? p) {
    if (p == null || p.totalCount == 0) return _OverlayState.notDownloaded;
    if (p.anyDownloading) return _OverlayState.downloading;
    if (p.downloadedCount == 0) return _OverlayState.notDownloaded;
    if (p.downloadedCount < p.totalCount) return _OverlayState.partial;
    return _OverlayState.done;
  }

  @override
  Widget build(BuildContext context) {
    final progress = _notifier?.value;
    final state = _stateFor(progress);

    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.child,

        // Progress overlay while downloading
        if (state == _OverlayState.downloading)
          Positioned.fill(
            child: IgnorePointer(
              child: Container(
                color: Colors.black.withValues(alpha: 0.45),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: widget.indicatorSize,
                        height: widget.indicatorSize,
                        child: CircularProgressIndicator(
                          value: (progress?.overallProgress ?? 0) > 0
                              ? progress!.overallProgress
                              : null,
                          color: Colors.white,
                          strokeWidth: 3,
                        ),
                      ),
                      if ((progress?.overallProgress ?? 0) > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '${(progress!.overallProgress * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),

        // Download badge - top-right primary rounded rect with white arrow.
        // Shown when not downloaded or partially downloaded.
        // In compact contexts (e.g. list tile thumbnails) the badge scales
        // down to fit the top-right quadrant of the cover.
        if (state == _OverlayState.notDownloaded ||
            state == _OverlayState.partial)
          Positioned(
            top: 6,
            right: 6,
            child: IgnorePointer(
              child: Container(
                padding: EdgeInsets.all(widget.iconSize <= 24 ? 3 : 6),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary,
                  borderRadius:
                      BorderRadius.circular(widget.iconSize <= 24 ? 5 : 8),
                ),
                child: Icon(
                  Icons.download_rounded,
                  size: widget.iconSize <= 24 ? 12 : 20,
                  color: Colors.white,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
