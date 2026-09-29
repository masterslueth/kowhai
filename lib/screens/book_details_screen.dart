import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../locator.dart';
import '../models/audiobook.dart';
import '../models/bookmark.dart';
import '../services/drive_download_manager.dart';
import '../services/download_progress_tracker.dart';
import '../services/drive_library_service.dart';
import '../services/position_service.dart';
import '../widgets/audio_handler_scope.dart';
import '../widgets/book_cover.dart';
import '../utils/bookmark_undo.dart';
import 'library/drive_download_sheet.dart';
import '../utils/formatters.dart';
import 'player_screen.dart';

class BookDetailsScreen extends StatelessWidget {
  final Audiobook book;

  const BookDetailsScreen({super.key, required this.book});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 280,
            pinned: true,
            foregroundColor: Colors.white,
            backgroundColor: Theme.of(context).colorScheme.surface,
            flexibleSpace: FlexibleSpaceBar(
              background: _CoverBackground(book: book),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
              child: _BookContent(book: book),
            ),
          ),
        ],
      ),
    );
  }
}

class _CoverBackground extends StatelessWidget {
  final Audiobook book;

  const _CoverBackground({required this.book});

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        BookCover(book: book, iconSize: 80, decodeSize: 1024),
        // Gradient fade at bottom so AppBar back button stays legible
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.5, 1.0],
                colors: [
                  Colors.transparent,
                  Colors.black.withValues(alpha: 0.6),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _BookContent extends StatelessWidget {
  final Audiobook book;

  const _BookContent({required this.book});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          book.title,
          style: theme.textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        if (book.author != null) ...[
          const SizedBox(height: 4),
          Text(
            'By ${book.author}',
            style: theme.textTheme.bodyLarge,
          ),
        ],
        if (book.narrator != null) ...[
          const SizedBox(height: 2),
          Text(
            'Read by ${book.narrator}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
            ),
          ),
        ],
        if (book.series != null) ...[
          const SizedBox(height: 2),
          Text(
            '${book.series}${book.seriesIndex != null ? ' #${book.seriesIndex}' : ''}',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
        if (book.duration != null) ...[
          const SizedBox(height: 4),
          Text(
            fmtHourMin(book.duration!),
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ],
        const SizedBox(height: 24),
        _ActionButtons(book: book),
        if (book.description != null) ...[
          const SizedBox(height: 24),
          _DescriptionSection(description: book.description!),
        ],
        const SizedBox(height: 24),
        _BookmarksSection(book: book),
        const SizedBox(height: 24),
        _MetadataSection(book: book),
      ],
    );
  }

}

class _ActionButtons extends StatefulWidget {
  final Audiobook book;

  const _ActionButtons({required this.book});

  @override
  State<_ActionButtons> createState() => _ActionButtonsState();
}

class _ActionButtonsState extends State<_ActionButtons> {
  FolderProgressNotifier? _notifier;

  BookDownloadProgress? get _progress =>
      _notifier?.value ?? _seedFallback();

  /// Pre-seed snapshot for the very first frames before the tracker's lazy
  /// DB seed completes; derived from whatever the widget was handed.
  BookDownloadProgress? _seedFallback() {
    final meta = widget.book.driveMetadata;
    if (meta == null) return null;
    return BookDownloadProgress(
      folderId: meta.folderId,
      downloadedCount: widget.book.audioFiles.length,
      totalCount: meta.totalFileCount,
    );
  }

  bool get _isDownloading => _progress?.anyDownloading ?? false;

  @override
  void initState() {
    super.initState();
    // R14 guard: source==drive with missing metadata is a boundary error —
    // treat as non-Drive rather than crash.
    final folderId = widget.book.driveMetadata?.folderId;
    if (widget.book.source == AudiobookSource.drive && folderId != null) {
      _notifier = locator<DownloadProgressTracker>().listenableFor(folderId)
        ..addListener(_onChange);
      locator<DownloadProgressTracker>().ensureSeeded(folderId);
    }
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _notifier?.removeListener(_onChange);
    super.dispose();
  }

  


  Future<void> _cancelAndRemove(BuildContext context) async {
    final theme = Theme.of(context);
    final title =
        _isDownloading ? 'Cancel download?' : 'Remove from device?';
    final body = _isDownloading
        ? 'The download will be stopped and any partially downloaded '
            'files for "${widget.book.title}" will be deleted.'
        : 'Downloaded files for "${widget.book.title}" will be deleted. '
            'The book will remain in your Google Drive.';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              _isDownloading ? 'Stop & remove' : 'Remove',
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    // `driveMetadata` is nullable and the model documents that it is non-null
    // only when source == drive — i.e. the type system says this can be null
    // under exactly the condition that leads here. See the R14 guard at the
    // top of build() for the same boundary handled as a non-Drive case.
    final folderId = widget.book.driveMetadata?.folderId;
    if (folderId == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't identify this Drive book.")),
        );
      }
      return;
    }
    final dlManager = locator<DriveDownloadManager>();
    final driveLib = locator<DriveLibraryService>();
    await dlManager.cancelDownload(folderId);
    await driveLib.undownloadBook(folderId);
    if (context.mounted) Navigator.pop(context, folderId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDrive = widget.book.source == AudiobookSource.drive;
    // Tracker snapshot is authoritative once seeded; before that fall back to
    // whatever the widget was constructed with (see _seedFallback).
    final snap = _progress;
    final downloaded = snap?.downloadedCount ?? widget.book.audioFiles.length;
    final total = snap?.totalCount ??
        (widget.book.driveMetadata?.totalFileCount ?? 0);
    final fullyDownloaded = isDrive && total > 0 && downloaded >= total;
    final hasDownloaded = isDrive && (downloaded > 0 || _isDownloading);
    final notDownloaded = isDrive && !fullyDownloaded && !_isDownloading;
    final overallProgress = snap?.overallProgress ?? 0;
    final totalBytes = snap?.totalBytes ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: () async {
            if (isDrive && notDownloaded) {
              await showDriveDownloadSheet(context, widget.book);
              return;
            }
            // For Drive books that are fully downloaded, widget.book.audioFiles
            // may be stale (empty) if the download completed while this screen
            // was open. Re-fetch from the service to get the actual file paths.
            var bookToPlay = widget.book;
            if (isDrive && bookToPlay.audioFiles.isEmpty) {
              final folderId = bookToPlay.driveMetadata?.folderId;
              if (folderId == null) {
                // Same boundary as above: no Drive folder means there is
                // nothing to promote from. Fall through to the DB-only load.
                final dbOnly = await locator<DriveLibraryService>()
                    .loadDriveBooks();
                final match = dbOnly.firstWhereOrNull(
                    (b) => b.path == bookToPlay.path);
                if (match == null) return;
                bookToPlay = match;
              } else {
                final fresh = await locator<DriveLibraryService>()
                    .promoteToLocal(folderId);
                if (fresh != null) {
                  bookToPlay = fresh;
                } else {
                  // promoteToLocal failed (e.g. scan error or path mismatch) —
                  // fall back to DB-only load which at least provides audio paths.
                  final dbBooks =
                      await locator<DriveLibraryService>().loadDriveBooks();
                  final dbBook = dbBooks.firstWhereOrNull(
                      (b) => b.driveMetadata?.folderId == folderId);
                  if (dbBook != null && dbBook.audioFiles.isNotEmpty) {
                    bookToPlay = dbBook;
                  }
                }
              }
            }
            if (!context.mounted) return;
            Navigator.pushReplacement(
              context,
              MaterialPageRoute(builder: (_) => PlayerScreen(book: bookToPlay)),
            );
          },
          icon: const Icon(Icons.play_arrow_rounded),
          label: const Text('Start listening'),
        ),
        if (_isDownloading) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: null, // disabled
            icon: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                value: overallProgress > 0 ? overallProgress : null,
                strokeWidth: 2,
                color: theme.colorScheme.primary.withValues(alpha: 0.5),
              ),
            ),
            label: Text(overallProgress > 0
                ? 'Downloading — ${(overallProgress * 100).toStringAsFixed(0)}%'
                : 'Downloading…'),
          ),
        ] else if (notDownloaded) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => showDriveDownloadSheet(context, widget.book),
            icon: const Icon(Icons.download_rounded),
            label: Text(
              totalBytes > 0
                  ? 'Download to device (${formatBytes(totalBytes)})'
                  : 'Download to device',
            ),
          ),
        ],
        if (hasDownloaded) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
              side: BorderSide(
                  color: theme.colorScheme.error.withValues(alpha: 0.5)),
            ),
            onPressed: () => _cancelAndRemove(context),
            icon: Icon(_isDownloading
                ? Icons.cancel_outlined
                : Icons.delete_outline_rounded),
            label: Text(_isDownloading ? 'Stop & remove' : 'Remove from device'),
          ),
        ],
      ],
    );
  }
}

class _DescriptionSection extends StatefulWidget {
  final String description;

  const _DescriptionSection({required this.description});

  @override
  State<_DescriptionSection> createState() => _DescriptionSectionState();
}

class _DescriptionSectionState extends State<_DescriptionSection> {
  bool _expanded = false;

  String get _preview {
    final newlineIdx = widget.description.indexOf('\n\n');
    if (newlineIdx > 0 && newlineIdx <= 400) {
      return widget.description.substring(0, newlineIdx);
    }
    if (widget.description.length <= 300) return widget.description;
    return '${widget.description.substring(0, 300)}…';
  }

  bool get _needsExpansion => _preview != widget.description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Summary',
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _expanded ? widget.description : _preview,
          style: theme.textTheme.bodyMedium,
        ),
        if (_needsExpansion) ...[
          const SizedBox(height: 4),
          GestureDetector(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Text(
              _expanded ? 'Read less' : 'Read more',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _MetadataSection extends StatelessWidget {
  final Audiobook book;

  const _MetadataSection({required this.book});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = <_MetadataRow>[
      _MetadataRow('Source', _sourceLabel(book)),
      if (book.series != null)
        _MetadataRow('Series',
            '${book.series}${book.seriesIndex != null ? ' #${book.seriesIndex}' : ''}'),
      if (book.releaseDate != null)
        _MetadataRow('Released', book.releaseDate!),
      if (book.language != null)
        _MetadataRow('Language', book.language!),
      if (book.publisher != null)
        _MetadataRow('Publisher', book.publisher!),
    ];

    if (rows.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Details',
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        ...rows.map((r) => _MetadataRowWidget(row: r)),
      ],
    );
  }

  String _sourceLabel(Audiobook b) {
    if (b.source == AudiobookSource.local) {
      final ext = b.audioFiles.isNotEmpty
          ? p.extension(b.audioFiles.first).toUpperCase().replaceFirst('.', '')
          : 'Unknown';
      return 'On device ($ext)';
    }
    final total = b.driveMetadata?.totalFileCount ?? 0;
    final dl = b.audioFiles.length;
    if (dl == 0) return 'Google Drive (Not downloaded)';
    if (dl >= total) return 'Google Drive (Downloaded)';
    return 'Google Drive ($dl/$total files)';
  }
}

class _MetadataRow {
  final String label;
  final String value;

  const _MetadataRow(this.label, this.value);
}

// ── Bookmarks section ─────────────────────────────────────────────────────────────────

class _BookmarksSection extends StatefulWidget {
  final Audiobook book;

  const _BookmarksSection({required this.book});

  @override
  State<_BookmarksSection> createState() => _BookmarksSectionState();
}

class _BookmarksSectionState extends State<_BookmarksSection> {
  List<Bookmark>? _bookmarks;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bookmarks =
        await locator<PositionService>().getBookmarks(widget.book.path);
    if (mounted) setState(() => _bookmarks = bookmarks);
  }

  Future<void> _delete(Bookmark bookmark) async {
    if (!mounted) return;
    // Dismissible asserts that the dismissed item has left the list by the
    // end of the onDismissed frame. Reloading from the DB two awaits later
    // left the row in the tree, which trips
    // 'A dismissed Dismissible widget is still part of the tree' (and is
    // guaranteed to rebuild, since the undo snackbar is shown on this
    // screen's own Scaffold). Drop it from local state synchronously.
    setState(() => _bookmarks?.removeWhere((b) => b.id == bookmark.id));
    await deleteBookmarkWithUndo(context, bookmark);
  }

  void _jumpTo(BuildContext context, Bookmark bookmark) {
    final book = widget.book;
    final ah = AudioHandlerScope.of(context).audioHandler;
    final isM4b = book.chapters.isNotEmpty;
    if (isM4b) {
      ah.seek(Duration(milliseconds: bookmark.positionMs));
    } else {
      // Clamp: chapterIndex is persisted and restored verbatim, so a book
      // whose files changed since the bookmark was written can yield an index
      // outside the loaded sequence, which just_audio's seek asserts on.
      final maxIndex = ah.player.sequence.length - 1;
      if (maxIndex < 0) return;
      final index = bookmark.chapterIndex.clamp(0, maxIndex);
      final startMs = calculateGlobalPosition(
        chapterIndex: index,
        chapterPosition: Duration.zero,
        chapterDurations: book.chapterDurations,
      );
      ah.player.seek(
        Duration(
            milliseconds:
                (bookmark.positionMs - startMs).clamp(0, bookmark.positionMs)),
        index: index,
      );
    }
    ah.play();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
          builder: (_) => PlayerScreen(book: widget.book)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bookmarks = _bookmarks;

    if (bookmarks == null || bookmarks.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Bookmarks',
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 8),
        ...bookmarks.map((bm) => Dismissible(
              key: ValueKey(bm.id),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 16),
                color: theme.colorScheme.errorContainer,
                child: Icon(Icons.delete_outline_rounded,
                    color: theme.colorScheme.onErrorContainer),
              ),
              onDismissed: (_) => _delete(bm),
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.bookmark_rounded,
                    color: theme.colorScheme.primary),
                title: Text(bm.label,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: bm.notes != null
                    ? Text(bm.notes!,
                        maxLines: 1, overflow: TextOverflow.ellipsis)
                    : null,
                trailing: Text(
                  fmtHMSec(Duration(milliseconds: bm.positionMs)),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color:
                        theme.colorScheme.onSurface.withValues(alpha: 0.55),
                  ),
                ),
                onTap: () => _jumpTo(context, bm),
              ),
            )),
      ],
    );
  }
}
class _MetadataRowWidget extends StatelessWidget {
  final _MetadataRow row;

  const _MetadataRowWidget({required this.row});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              row.label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
              ),
            ),
          ),
          Expanded(
            child: Text(
              row.value,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
