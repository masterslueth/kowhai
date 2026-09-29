import 'dart:async';
import 'dart:io' show File;
import 'package:audio_service/audio_service.dart';
import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import '../models/audiobook.dart';
import '../models/availability_filter_state.dart';
import '../services/audio_handler.dart';
import '../services/drive_book_repository.dart';
import '../services/drive_library_service.dart';
import '../services/drive_service.dart';
import '../utils/formatters.dart';
import '../services/enrichment_service.dart';
import '../services/position_service.dart';
import '../services/preferences_service.dart';
import '../services/scanner_service.dart';
import '../widgets/audio_handler_scope.dart';
import '../widgets/library_overflow_menu.dart';
import '../widgets/mini_player.dart';
import '../widgets/sleep_timer_indicator.dart';
import 'book_details_screen.dart';
import 'history_screen.dart';
import 'player_screen.dart';
import 'settings_screen.dart';
import '../locator.dart';
import '../services/download_progress_tracker.dart';
import '../utils/library_queries.dart';
import 'library/book_views.dart';
import 'library/drive_scan_overlay.dart';
import 'library/drive_download_sheet.dart';
import 'library/library_view_bar.dart';
import 'library/library_filter_sheet.dart';
import 'library/library_sort_sheet.dart';

enum _ViewMode { grid, list }

class LibraryScreen extends StatefulWidget {
  /// When true, forces a Drive sync on first load regardless of the
  /// refresh-on-startup preference. Used by onboarding after Drive setup
  /// so new users see their books immediately without a manual rescan.
  final bool initialSyncDrive;
  const LibraryScreen({super.key, this.initialSyncDrive = false});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<Audiobook>? _books;       // sorted display order
  List<Audiobook>? _rawBooks;    // unsorted, straight from scanner
  List<Audiobook> _driveBooks = []; // Drive books (unsorted)
  Map<String, BookStatus> _statuses = {};
  String? _error;
  bool _syncing = false;
  String _scanStatus = 'Scanning your libraryâ€¦';
  bool _hasLocalFolder = false;
  bool _hasDriveConfigured = false;
  Set<String> _syncFoundPaths = {};
  _ViewMode _viewMode = _ViewMode.grid;

  // Search state.
  bool _isSearching = false;
String _searchQuery = '';
final TextEditingController _searchController = TextEditingController();
// Debounces keystrokes so the full filter pipeline runs at most ~7Ã—/s
// instead of on every character. Clear actions flush immediately.
Timer? _searchDebounce;

  // Status filter pill selection (null = show all).
  BookStatus? _statusFilter;

  // Availability filter selection.
  AvailabilityFilterState _availabilityFilter = AvailabilityFilterState.all;

  // User-selected sort order. Defaults to last-played until prefs load.
  LibrarySortOrder _sortOrder = LibrarySortOrder.lastPlayed;

  // Cached download size labels for Drive books not yet downloaded.
  // Key: book.path, Value: formatted size string e.g. "123.4 MB".
  final Map<String, String> _downloadSizeLabels = {};

  // Drive books currently being downloaded (tracked by folderId).
  

  // Currently-active book tracking (for badge).
  String? _activePath;
  bool _isPlaying = false;
  StreamSubscription<PlaybackState>? _playbackSub;
  StreamSubscription<({String bookPath, String coverPath})>? _enrichSub;
  VoidCallback? _downloadingSetListener;

  late final DownloadProgressTracker _tracker;
  late final KowhaiHandler _audioHandler;
  bool _didInit = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didInit) {
      _didInit = true;
      _audioHandler = AudioHandlerScope.of(context).audioHandler;
      _initLibrary();
      _enrichSub = locator<EnrichmentService>().onCoverFetched.listen(_onCoverFetched);
      // Progress state flows through the shared tracker; this screen only
      // reacts to completion (promote/refresh) and the busy-set for tiles.
      _tracker = locator<DownloadProgressTracker>();
      _tracker.onBookCompleted = _refreshDriveBook;
      _tracker.onCoverCompleted = _refreshDriveBook;
      _downloadingSetListener = () {
        if (mounted) setState(() {});
      };
      _tracker.downloadingFolders.addListener(_downloadingSetListener!);
      _playbackSub = _audioHandler.playbackState.listen((state) {
        final newPath = _audioHandler.currentBook?.path;
        if (newPath != _activePath || state.playing != _isPlaying) {
          setState(() {
            _activePath = newPath;
            _isPlaying = state.playing;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _playbackSub?.cancel();
    _enrichSub?.cancel();
    if (_downloadingSetListener != null) {
      _tracker.downloadingFolders.removeListener(_downloadingSetListener!);
    }
    if (_tracker.onBookCompleted == _refreshDriveBook) {
      _tracker.onBookCompleted = null;
      _tracker.onCoverCompleted = null;
    }
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _openSearch() => setState(() => _isSearching = true);

  void _closeSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _isSearching = false;
      _searchQuery = '';
    });
  }

  List<Audiobook> get _displayedBooks {
    // Pipeline: availability â†’ search â†’ status
    final availFiltered = applyAvailabilityFilter(_books ?? [], _availabilityFilter);
    final searchFiltered = filterBooks(availFiltered, _searchQuery);
    return applyStatusFilter(searchFiltered, _statuses, _statusFilter);
  }

  // â”€â”€ Scan + sort â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  /// Toggles grid/list and persists the choice across launches.
  Future<void> _toggleViewMode() async {
    setState(() {
      _viewMode =
          _viewMode == _ViewMode.grid ? _ViewMode.list : _ViewMode.grid;
    });
    await locator<PreferencesService>()
        .setViewMode(_viewMode == _ViewMode.grid ? 'grid' : 'list');
  }

  Future<void> _initLibrary() async {
    final prefs = locator<PreferencesService>();
    final sortName = await prefs.getLibrarySort();
    final availFilter = await prefs.getAvailabilityFilter();
    final statusFilter = await prefs.getStatusFilter();
    final viewModeName = await prefs.getViewMode();
    final driveConnected = locator<DriveService>().currentAccount != null;
    if (mounted) {
      setState(() {
        _sortOrder = LibrarySortOrder.fromName(sortName);
        // Reset to `all` if Drive is not connected â€” the filter is meaningless
        // without a Drive account and the section won't be shown in the UI.
        _availabilityFilter = driveConnected ? availFilter : AvailabilityFilterState.all;
        _statusFilter = statusFilter;
        _viewMode = viewModeName == 'list' ? _ViewMode.list : _ViewMode.grid;
      });
    }
    final shouldScan = widget.initialSyncDrive || await prefs.getRefreshOnStartup();
    // Always load previously discovered books so the library isn't empty on
    // launch. When refresh-on-startup is off, skip the Drive network sync â€”
    // cached Drive books still load from the DB.
    _scan(syncWithDrive: shouldScan);
  }

  /// Called by the scanner as each book is found. Appends it to the visible
  /// list immediately so the user sees books appear one by one during a scan.
  void _onBookFound(Audiobook book) {
    if (!mounted) return;
    _syncFoundPaths.add(book.path);
    _rawBooks ??= [];
    final idx = _rawBooks!.indexWhere((b) => b.path == book.path);
    if (idx == -1) {
      // New book â€” optimistic append to both lists (sort applied at end).
      setState(() {
        _rawBooks = [..._rawBooks!, book];
        _books = [...(_books ?? []), book];
      });
    } else {
      // Existing book â€” refresh metadata in place without reordering.
      setState(() {
        _rawBooks = List.from(_rawBooks!)..[idx] = book;
      });
    }
  }

  Future<void> _scan({bool syncWithDrive = true}) async {
    _syncFoundPaths = {};
    setState(() {
      _syncing = true;
      _scanStatus = 'Scanning your libraryâ€¦';
      _error = null;
      // Intentionally NOT clearing _rawBooks or _books so existing
      // books remain visible while the resync runs in the background.
    });
    try {
      final path = await locator<PreferencesService>().getLibraryPath();

      // No local folder â€” the wait is entirely on Drive, so say so.
      if (path == null && mounted) {
        setState(() => _scanStatus = 'Checking Google Driveâ€¦');
      }

      // Exclude Drive-managed dirs from local scan to avoid double-counting
      // books downloaded to the local library folder.
      final driveExcludes = path != null
          ? await locator<DriveLibraryService>().driveBookDirs()
          : <String>{};

      final results = await Future.wait([
        path != null
            ? locator<ScannerService>().scanFolder(
                path,
                excludePaths: driveExcludes,
                onBookFound: _onBookFound, // streams books into UI as found
              )
            : Future.value(<Audiobook>[]),
        // rescanDrive syncs with Drive when connected; falls back to DB-only
        // when offline or not configured. loadDriveBooks skips the network.
        syncWithDrive
            ? locator<DriveLibraryService>().rescanDrive()
            : locator<DriveLibraryService>().loadDriveBooks(),
      ]);
      final driveBooks = results[1];

      // Remove stale local books that were not found in this scan pass.
      final drivePaths = driveBooks.map((b) => b.path).toSet();
      _rawBooks = (_rawBooks ?? [])
          .where((b) =>
              drivePaths.contains(b.path) ||
              _syncFoundPaths.contains(b.path))
          .toList();

      final driveConfigured =
          await locator<PreferencesService>().getDriveRootFolder() != null;
      _hasLocalFolder = path != null;
      _hasDriveConfigured = driveConfigured;
      if (path == null && driveBooks.isEmpty && !driveConfigured) {
        if (!mounted) return;
        setState(() {
          _syncing = false;
        });
        return;
      }

      final enrichEnabled = await locator<PreferencesService>().getMetadataEnrichment();

      if (mounted && enrichEnabled) {
        setState(() => _scanStatus = 'Loading coversâ€¦');
      }

      // Apply cached enriched covers only when enrichment is enabled.
      // When disabled, treat each scan as a cache flush and show only
      // embedded artwork (or the default icon).
      final cachedCovers = enrichEnabled
          ? await locator<EnrichmentService>().getAllEnrichedCovers()
          : <String, String>{};
      _rawBooks = applyCachedCovers(_rawBooks ?? [], cachedCovers);
      _driveBooks = driveBooks;

      // Single DB read + full sort after all books are in.
      await _applySort();
      if (!mounted) return;
      setState(() => _syncing = false);

      // Start background enrichment for books missing covers.
      if (enrichEnabled) {
        unawaited(locator<EnrichmentService>().enqueueBooks(_rawBooks!));
      }

      // Restore the last-played book into the handler so the mini player
      // appears immediately on launch (without auto-playing).
      if (_audioHandler.currentBook == null) {
        final lastPath = await locator<PositionService>().getLastPlayedBookPath();
        if (lastPath != null) {
          final allBooks = [...(_rawBooks ?? []), ...driveBooks];
          final book = allBooks.where((b) => b.path == lastPath).firstOrNull;
          if (book != null) await _audioHandler.loadBook(book);
        }
      }
    } catch (e, st) {
      debugPrint('[LibraryScreen] scan failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _error = friendlyScanError(e);
        _syncing = false;
      });
    }
  }

  /// Persist the new sort order and re-sort the library.
  Future<void> _setSortOrder(LibrarySortOrder order) async {
    if (order == _sortOrder) return;
    setState(() => _sortOrder = order);
    await locator<PreferencesService>().setLibrarySort(order.name);
    await _applySort();
  }

  /// Loads positions from DB, sorts books, and updates state.
  Future<void> _applySort() async {
    final raw = _rawBooks;
    if (raw == null) return;

    final all = [...raw, ..._driveBooks];

    final positions = await locator<PositionService>().getAllPositions();
    final statuses = await locator<PositionService>().getAllStatuses();

    // dateAdded: use the folder's mtime for local books. Cheap enough for
    // typical library sizes (hundreds of books); skip on error.
    final dateAdded = <String, int>{};
    if (_sortOrder == LibrarySortOrder.dateAdded) {
      for (final b in all) {
        try {
          final st = await File(b.path).stat();
          dateAdded[b.path] = st.modified.millisecondsSinceEpoch;
        } catch (_) {
          // Drive-only books or stat errors fall through to 0.
        }
      }
    }

    // Prefetch formatted download sizes for Drive books that aren't fully
    // downloaded, so list tiles can show them without firing requests during
    // build. The cache map makes this idempotent across re-sorts.
    for (final b in all) {
      await _ensureDownloadSizeLabel(b);
    }

    if (!mounted) return;
    setState(() {
      _books = sortBooks(
        all,
        _sortOrder,
        positions: positions,
        dateAddedMs: dateAdded,
      );
      _statuses = statuses;
    });
  }

  void _onCoverFetched(({String bookPath, String coverPath}) event) {
    final raw = _rawBooks;
    if (raw == null) return;
    final idx = raw.indexWhere((b) => b.path == event.bookPath);
    if (idx == -1) return;
    final updated = List<Audiobook>.from(raw);
    updated[idx] = raw[idx].copyWith(coverImagePath: event.coverPath);
    _rawBooks = updated;
    _applySort();
  }

Future<void> _refreshDriveBook(String folderId) async {
    final driveLibService = locator<DriveLibraryService>();
    final driveRepo = locator<DriveBookRepository>();
    final files = await driveRepo.getFilesForBook(folderId);
    final allDone = files.isNotEmpty && files.every((f) => f.downloadState == DriveDownloadState.done);

    Audiobook? updated;
    if (allDone) {
      // Promote: re-scan local dir for full metadata
      updated = await driveLibService.promoteToLocal(folderId);
    }
    // Fallback: reload from DB (covers partial downloads or failed promote)
    if (updated == null) {
      final freshBooks = await driveLibService.loadDriveBooks();
      updated = freshBooks.firstWhereOrNull(
        (b) => b.driveMetadata?.folderId == folderId,
      );
    }
    if (updated == null) return;

    final idx = _driveBooks.indexWhere((b) => b.driveMetadata?.folderId == folderId);
    if (idx != -1) {
      _driveBooks = List<Audiobook>.from(_driveBooks)..[idx] = updated;
    } else {
      _driveBooks = [..._driveBooks, updated];
    }
    // _applySort() rebuilds _books from _rawBooks + _driveBooks and calls
    // setState, which causes _displayedBooks to recompute via
    // applyAvailabilityFilter â†’ filterBooks â†’ applyStatusFilter.
    // This means a newly-downloaded Drive book automatically disappears from
    // the `driveOnly` view and appears in the `availableOffline` view without
    // any manual rescan (Requirements 2.6, 2.7).
    await _applySort();
  }

  Future<void> _openPlayer(BuildContext context, Audiobook book) async {
    if (book.isDrmLocked) {
      showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          icon: const Icon(Icons.lock_rounded),
          title: const Text('DRM-Protected File'),
          content: const Text(
            'This audiobook is in Audible\'s AAX/AA format and is protected '
            'by DRM (Digital Rights Management). KÅwhai cannot play '
            'DRM-protected files.\n\n'
            'To listen, use the Audible app, or convert the file to a '
            'DRM-free format using a tool that supports your local laws.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    // Drive book: ensure files are available and metadata is fully populated
    if (book.source == AudiobookSource.drive &&
        (book.audioFiles.isEmpty || book.chapterDurations.isEmpty)) {
      final folderId = book.driveMetadata?.folderId;
      if (folderId == null) {
        // A Drive-sourced book with no folder metadata cannot be resolved.
        // The model documents this state as reachable, and book_details_screen
        // handles it as a non-Drive boundary rather than crashing.
        return;
      }
      final files = await locator<DriveBookRepository>().getFilesForBook(folderId);
      final allDone = files.isNotEmpty &&
          files.every((f) => f.downloadState == DriveDownloadState.done);
      if (allDone) {
        await _refreshDriveBook(folderId);
        final refreshed = _driveBooks.firstWhereOrNull(
          (b) => b.driveMetadata?.folderId == folderId,
        );
        if (refreshed != null && refreshed.audioFiles.isNotEmpty) {
          book = refreshed;
        } else if (book.audioFiles.isEmpty) {
          if (context.mounted) showDriveDownloadSheet(context, book);
          return;
        }
      } else if (book.audioFiles.isEmpty) {
        // Check if a download is already in progress.
        final anyDownloading = files.any(
            (f) => f.downloadState == DriveDownloadState.downloading);
        if (anyDownloading) {
          if (context.mounted) {
            final cancelled =
                await showDriveDownloadProgressSheet(context, book);
            if (cancelled == true) _refreshDriveBook(folderId);
          }
        } else {
          if (context.mounted) showDriveDownloadSheet(context, book);
        }
        return;
      }
    }

    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PlayerScreen(book: book)),
    ).then((_) => _applySort()); // re-sort when returning from player
  }

  void _openDetails(BuildContext context, Audiobook book) {
    Navigator.push<dynamic>(
      context,
      MaterialPageRoute(builder: (_) => BookDetailsScreen(book: book)),
    ).then((result) {
      if (result == true) {
        _scan();
      } else if (result is String) {
        // Drive book was undownloaded â€” result is the folderId.
        _refreshDriveBook(result);
      } else {
        _applySort();
      }
    });
  }

  // â”€â”€ Build â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Library'),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Center(
              child: SleepTimerIndicator(onTap: _openCurrentBookPlayer),
            ),
          ),
          IconButton(
            icon: Icon(_isSearching
                ? Icons.close_rounded
                : Icons.search_rounded),
            onPressed: _isSearching
                ? _closeSearch
                : (_books != null ? _openSearch : null),
            tooltip: _isSearching ? 'Close search' : 'Search',
          ),
          LibraryOverflowMenu(
            syncing: _syncing,
            onHistory: _openHistory,
            onRescan: _syncing ? null : _scan,
            onSettings: _openSettings,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _searchBar(),
          Expanded(child: _body()),
          MiniPlayer(),
        ],
      ),
    );
  }

  void _openHistory() {
    final books = _rawBooks;
    if (books == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => HistoryScreen(books: [...books, ..._driveBooks]),
      ),
    );
  }

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          onFolderChanged: _scan,
          onDriveRescanned: _scan,
        ),
      ),
    );
  }

  Widget _searchBar() {
    final theme = Theme.of(context);
    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: _isSearching
          ? Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                controller: _searchController,
                autofocus: true,
                onChanged: (v) {
                  _searchDebounce?.cancel();
                  _searchDebounce =
                      Timer(const Duration(milliseconds: 150), () {
                    if (mounted) setState(() => _searchQuery = v);
                  });
                },
                decoration: InputDecoration(
                  hintText: 'Search by title or authorâ€¦',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: _searchQuery.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear_rounded),
                          onPressed: () {
                            _searchDebounce?.cancel();
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                          tooltip: 'Clear',
                        )
                      : null,
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                ),
              ),
            )
          : const SizedBox(width: double.infinity),
    );
  }

  Widget _body() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 64, color: Theme.of(context).colorScheme.error),
              const SizedBox(height: 16),
              Text(
                _error!,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.error),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Retry'),
                onPressed: _scan,
              ),
            ],
          ),
        ),
      );
    }

    final allBooks = _books ?? [];

    if (allBooks.isEmpty) {
      if (_syncing) {
        return DriveScanOverlay(status: _scanStatus);
      }
      final content = emptyStateContent(
        hasLocalFolder: _hasLocalFolder,
        hasDriveConfigured: _hasDriveConfigured,
      );
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.library_music_outlined,
                  size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              Text(
                content.title,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(content.message, textAlign: TextAlign.center),
              if (content.showCta) ...[
                const SizedBox(height: 20),
                FilledButton.icon(
                  icon: const Icon(Icons.settings_rounded),
                  label: const Text('Open Settings'),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SettingsScreen(
                        onFolderChanged: _scan,
                        onDriveRescanned: _scan,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final books = _displayedBooks;

    if (books.isEmpty && _statusFilter == null && _searchQuery.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off_rounded,
                  size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text(
                'No audiobooks found.\n\nMake sure your folder contains subfolders with audio files.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _viewBar(books.length),
        Expanded(
          child: books.isEmpty
              ? LibraryNoMatchesView(
                  searchQuery: _searchQuery,
                  statusFilter: _statusFilter,
                  availabilityFilter: _availabilityFilter,
                  statusLabel: _statusFilterLabel,
                  onClearFilters: _clearSearchAndFilters,
                )
              : _viewMode == _ViewMode.grid
                  ? _grid(books)
                  : _list(books),
        ),
      ],
    );
  }

  // â”€â”€ View bar (pinned, below search) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  Widget _viewBar(int count) {
    return LibraryViewBar(
      count: count,
      isGridView: _viewMode == _ViewMode.grid,
      onToggleViewMode: _toggleViewMode,
      statusFilter: _statusFilter,
      availabilityFilter: _availabilityFilter,
      sortOrder: _sortOrder,
      statusLabel: _statusFilterLabel,
      onOpenFilter: _openFilterSheet,
      onOpenSort: _openSortSheet,
    );
  }

  Future<void> _openFilterSheet() async {
    final searchFiltered = filterBooks(_books ?? [], _searchQuery);
    await showLibraryFilterSheet(
      context,
      searchFilteredBooks: searchFiltered,
      statuses: _statuses,
      statusFilter: _statusFilter,
      availabilityFilter: _availabilityFilter,
      hasDriveBooks: _driveBooks.isNotEmpty,
      onStatusChanged: (s) => setState(() => _statusFilter = s),
      onAvailabilityChanged: (s) => setState(() => _availabilityFilter = s),
    );
  }

  Future<void> _openSortSheet() async {
    await showLibrarySortSheet(
      context,
      current: _sortOrder,
      onOrderSelected: _setSortOrder,
    );
  }

  void _openCurrentBookPlayer() {
    final ah = AudioHandlerScope.of(context).audioHandler;
    final book = ah.currentBook;
    if (book == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PlayerScreen(book: book)),
    );
  }

  void _clearSearchAndFilters() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _statusFilter = null;
      _availabilityFilter = AvailabilityFilterState.all;
    });
    final prefs = locator<PreferencesService>();
    prefs.setStatusFilter(null);
    prefs.setAvailabilityFilter(AvailabilityFilterState.all);
  }

  String _statusFilterLabel(BookStatus s) => switch (s) {
        BookStatus.notStarted => 'Not started',
        BookStatus.inProgress => 'In progress',
        BookStatus.finished   => 'Finished',
      };

  Widget _grid(List<Audiobook> books) {
    return buildLibraryGrid(
      books: books,
      activePath: _activePath,
      isPlaying: _isPlaying,
      statuses: _statuses,
      onOpenPlayer: (b) => _openPlayer(context, b),
      onOpenDetails: (b) => _openDetails(context, b),
      onRefresh: _scan,
    );
  }

  /// Fetches and caches the formatted download size for a Drive book that
  /// hasn't been fully downloaded yet. No-op if already cached or not applicable.
  Future<void> _ensureDownloadSizeLabel(Audiobook book) async {
    if (book.source != AudiobookSource.drive) return;
    final meta = book.driveMetadata;
    if (meta == null) return;
    // Only show for books that are not fully downloaded.
    final total = meta.totalFileCount;
    final downloaded = book.audioFiles.length;
    if (total > 0 && downloaded >= total) return;
    if (_downloadSizeLabels.containsKey(book.path)) return;

    final sizeBytes = await locator<DriveLibraryService>().totalSizeBytes(meta.folderId);
    if (!mounted) return;
    if (sizeBytes > 0) {
      setState(() => _downloadSizeLabels[book.path] = formatBytes(sizeBytes));
    }
  }

  Widget _list(List<Audiobook> books) {
    return buildLibraryList(
      books: books,
      activePath: _activePath,
      isPlaying: _isPlaying,
      statuses: _statuses,
      downloadingFolderIds: _tracker.downloadingFolders.value,
      downloadSizeLabels: _downloadSizeLabels,
      onOpenPlayer: (b) => _openPlayer(context, b),
      onOpenDetails: (b) => _openDetails(context, b),
      onDownloadPressed: (b) => showDriveDownloadSheet(context, b),
      onCancelDownloadPressed: (b) async {
        final folderId = b.driveMetadata?.folderId;
        if (folderId == null) return;
        final cancelled =
            await showDriveDownloadProgressSheet(context, b);
        if (cancelled == true) {
          await _refreshDriveBook(folderId);
        }
      },
      onRefresh: _scan,
    );
  }
}
