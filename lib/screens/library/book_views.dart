import 'package:flutter/material.dart';

import '../../models/audiobook.dart';
import '../../models/availability_filter_state.dart';
import '../../utils/library_queries.dart';
import '../../widgets/audiobook_card.dart';
import '../../widgets/audiobook_list_tile.dart';

/// Grid/list renderers for the library body plus the filtered-empty view.
///
/// Extracted from library_screen.dart (decomposition phase 2); pure layout —
/// all behaviour arrives via callbacks.

Widget buildLibraryGrid({
  required List<Audiobook> books,
  required String? activePath,
  required bool isPlaying,
  required Map<String, BookStatus> statuses,
  required void Function(Audiobook) onOpenPlayer,
  required void Function(Audiobook) onOpenDetails,
  required Future<void> Function() onRefresh,
}) {
  // Responsive columns via MaxCrossAxisExtent: phones get ~2 columns,
  // tablets/foldables/landscape scale up without breakpoint tables.
  const spacing = 12.0;
  const padding = 12.0;

  return RefreshIndicator(
    onRefresh: onRefresh,
    child: GridView.builder(
      padding: const EdgeInsets.all(padding),
      // Without this, pull-to-refresh is inert whenever the content is
      // shorter than the viewport — common for a small library.
      physics: const AlwaysScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        childAspectRatio: 1, // pure square — no text block
      ),
      itemCount: books.length,
      itemBuilder: (context, i) => AudiobookCard(
        // Keyed by path: the collection re-sorts when the user changes sort
        // order, and without a key the elements are matched by index, so a
        // StatefulWidget holding a decoded image frame (BookCover) is handed a
        // different book and briefly paints the previous cover.
        key: ValueKey(books[i].path),
        book: books[i],
        isActive: books[i].path == activePath && isPlaying,
        status: statuses[books[i].path] ?? BookStatus.notStarted,
        onTap: () => onOpenPlayer(books[i]),
        onLongPress: () => onOpenDetails(books[i]),
      ),
    ),
  );
}

Widget buildLibraryList({
  required List<Audiobook> books,
  required String? activePath,
  required bool isPlaying,
  required Map<String, BookStatus> statuses,
  required Set<String> downloadingFolderIds,
  required Map<String, String> downloadSizeLabels,
  required void Function(Audiobook) onOpenPlayer,
  required void Function(Audiobook) onOpenDetails,
  required void Function(Audiobook) onDownloadPressed,
  required void Function(Audiobook) onCancelDownloadPressed,
  required Future<void> Function() onRefresh,
}) {
  return RefreshIndicator(
    onRefresh: onRefresh,
    child: ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: books.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 88),
      itemBuilder: (context, i) {
        final book = books[i];
        final folderId = book.driveMetadata?.folderId;
        final downloading =
            folderId != null && downloadingFolderIds.contains(folderId);
        return AudiobookListTile(
          key: ValueKey(book.path),
          book: book,
          isActive: book.path == activePath && isPlaying,
          status: statuses[book.path] ?? BookStatus.notStarted,
          onTap: () => onOpenPlayer(book),
          onDetailsPressed: () => onOpenDetails(book),
          isDownloading: downloading,
          downloadSizeLabel:
              downloading ? null : downloadSizeLabels[book.path],
          onDownloadPressed: !downloading && downloadSizeLabels[book.path] != null
              ? () => onDownloadPressed(book)
              : null,
          onCancelDownloadPressed:
              downloading ? () => onCancelDownloadPressed(book) : null,
        );
      },
    ),
  );
}

/// Shown when filters/search reduce the library to zero books.
class LibraryNoMatchesView extends StatelessWidget {
  final String searchQuery;
  final BookStatus? statusFilter;
  final AvailabilityFilterState availabilityFilter;
  final String Function(BookStatus) statusLabel;
  final VoidCallback onClearFilters;

  const LibraryNoMatchesView({
    super.key,
    required this.searchQuery,
    required this.statusFilter,
    required this.availabilityFilter,
    required this.statusLabel,
    required this.onClearFilters,
  });

  @override
  Widget build(BuildContext context) {
    final hasSearch = searchQuery.isNotEmpty;
    final hasAnyFilter =
        statusFilter != null || availabilityFilter != AvailabilityFilterState.all;

    final message = noMatchesMessage(
        searchQuery: searchQuery,
        statusFilter: statusFilter,
        availabilityFilter: availabilityFilter,
        statusLabel: statusLabel);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            if (hasSearch || hasAnyFilter) ...[
              const SizedBox(height: 20),
              TextButton.icon(
                icon: const Icon(Icons.filter_alt_off_rounded),
                label: const Text('Clear filters'),
                onPressed: onClearFilters,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
