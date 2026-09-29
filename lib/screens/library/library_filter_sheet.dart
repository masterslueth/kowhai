import 'package:flutter/material.dart';

import '../../locator.dart';
import '../../models/audiobook.dart';
import '../../models/availability_filter_state.dart';
import '../../services/drive_service.dart';
import '../../services/preferences_service.dart';
import '../../utils/library_queries.dart';

/// Shows the library filter bottom sheet (progress + availability pills).
///
/// Selections are written straight through to the owning screen via
/// [onStatusChanged]/[onAvailabilityChanged]; persistence happens here so the
/// sheet owns its own save semantics (mirrors the pre-extraction behaviour).
Future<void> showLibraryFilterSheet(
  BuildContext context, {
  required List<Audiobook> searchFilteredBooks,
  required Map<String, BookStatus> statuses,
  required BookStatus? statusFilter,
  required AvailabilityFilterState availabilityFilter,
  required bool hasDriveBooks,
  required ValueChanged<BookStatus?> onStatusChanged,
  required ValueChanged<AvailabilityFilterState> onAvailabilityChanged,
}) async {
  final allCount = searchFilteredBooks.length;
  final statusCounts = <BookStatus, int>{};
  for (final s in BookStatus.values) {
    statusCounts[s] = applyStatusFilter(searchFilteredBooks, statuses, s).length;
  }

  final availCounts = <AvailabilityFilterState, int>{};
  for (final s in AvailabilityFilterState.values) {
    availCounts[s] =
        applyAvailabilityFilter(searchFilteredBooks, s).length;
  }

  final driveConnected = locator<DriveService>().currentAccount != null;

  // Local selection state. The parameters above are `final` and captured by
  // the builder closure, so setSheetState(() {}) re-ran the builder against
  // the ORIGINAL arguments: the pill highlight never moved and canClear stayed
  // false, leaving "Clear all" permanently disabled for the life of the sheet.
  // The write-through callbacks below keep the parent in sync.
  var currentStatus = statusFilter;
  var currentAvailability = availabilityFilter;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => StatefulBuilder(
      builder: (sheetCtx, setSheetState) {
        final theme = Theme.of(sheetCtx);
        final maxHeight = MediaQuery.of(sheetCtx).size.height * 0.75;

        final canClear = currentStatus != null ||
            currentAvailability != AvailabilityFilterState.all;

        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.outlineVariant,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('Filter', style: theme.textTheme.titleMedium),
                        const SizedBox(height: 16),
                        Text(
                          'PROGRESS',
                          style: theme.textTheme.labelSmall?.copyWith(
                            letterSpacing: 1.2,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _pill(
                              context: sheetCtx,
                              label: 'All ($allCount)',
                              selected: currentStatus == null,
                              onTap: () {
                                onStatusChanged(null);
                                locator<PreferencesService>()
                                    .setStatusFilter(null);
                                setSheetState(() => currentStatus = null);
                              },
                            ),
                            for (final s in BookStatus.values)
                              _pill(
                                context: sheetCtx,
                                label:
                                    '${statusLabelOf(s)} (${statusCounts[s] ?? 0})',
                                selected: currentStatus == s,
                                onTap: () {
                                  onStatusChanged(s);
                                  locator<PreferencesService>()
                                      .setStatusFilter(s);
                                  setSheetState(() => currentStatus = s);
                                },
                              ),
                          ],
                        ),
                        if (driveConnected) ...[
                          const SizedBox(height: 20),
                          Text(
                            'AVAILABILITY',
                            style: theme.textTheme.labelSmall?.copyWith(
                              letterSpacing: 1.2,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 10),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              _pill(
                                context: sheetCtx,
                                label:
                                    'All (${availCounts[AvailabilityFilterState.all] ?? 0})',
                                selected: currentAvailability ==
                                    AvailabilityFilterState.all,
                                onTap: () {
                                  onAvailabilityChanged(
                                      AvailabilityFilterState.all);
                                  locator<PreferencesService>()
                                      .setAvailabilityFilter(
                                          AvailabilityFilterState.all);
                                  setSheetState(() => currentAvailability =
                                      AvailabilityFilterState.all);
                                },
                              ),
                              if (hasDriveBooks) ...[
                                _pill(
                                  context: sheetCtx,
                                  label:
                                      'Available offline (${availCounts[AvailabilityFilterState.availableOffline] ?? 0})',
                                  selected: currentAvailability ==
                                      AvailabilityFilterState.availableOffline,
                                  onTap: () {
                                    onAvailabilityChanged(
                                        AvailabilityFilterState.availableOffline);
                                    locator<PreferencesService>()
                                        .setAvailabilityFilter(
                                            AvailabilityFilterState
                                                .availableOffline);
                                    setSheetState(() => currentAvailability =
                                        AvailabilityFilterState.availableOffline);
                                  },
                                ),
                                _pill(
                                  context: sheetCtx,
                                  label:
                                      'Drive only (${availCounts[AvailabilityFilterState.driveOnly] ?? 0})',
                                  selected: currentAvailability ==
                                      AvailabilityFilterState.driveOnly,
                                  onTap: () {
                                    onAvailabilityChanged(
                                        AvailabilityFilterState.driveOnly);
                                    locator<PreferencesService>()
                                        .setAvailabilityFilter(
                                            AvailabilityFilterState.driveOnly);
                                    setSheetState(() => currentAvailability =
                                        AvailabilityFilterState.driveOnly);
                                  },
                                ),
                              ],
                            ],
                          ),
                        ],
                        const SizedBox(height: 20),
                        TextButton.icon(
                          icon: const Icon(Icons.filter_alt_off_rounded),
                          label: const Text('Clear all'),
                          onPressed: canClear
                              ? () {
                                  onStatusChanged(null);
                                  onAvailabilityChanged(
                                      AvailabilityFilterState.all);
                                  final prefs =
                                      locator<PreferencesService>();
                                  prefs.setStatusFilter(null);
                                  prefs.setAvailabilityFilter(
                                      AvailabilityFilterState.all);
                                  setSheetState(() {
                                    currentStatus = null;
                                    currentAvailability =
                                        AvailabilityFilterState.all;
                                  });
                                }
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

String statusLabelOf(BookStatus s) => switch (s) {
      BookStatus.notStarted => 'Not started',
      BookStatus.inProgress => 'In progress',
      BookStatus.finished => 'Finished',
    };

Widget _pill({
  required BuildContext context,
  required String label,
  required bool selected,
  required VoidCallback onTap,
}) {
  final cs = Theme.of(context).colorScheme;
  return Material(
    color:
        selected ? cs.primary.withValues(alpha: 0.16) : Colors.transparent,
    shape: StadiumBorder(
      side: BorderSide(
        width: 1.5,
        color: selected ? cs.primary : cs.outlineVariant,
      ),
    ),
    child: InkWell(
      customBorder: const StadiumBorder(),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? cs.primary : cs.onSurface,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    ),
  );
}
