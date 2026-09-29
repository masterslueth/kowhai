import 'dart:async';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';
import '../models/audiobook.dart';
import '../models/bookmark.dart';
import '../services/audio_handler.dart';
import '../services/position_service.dart';
import '../services/preferences_service.dart';
import '../services/sleep_timer_controller.dart';
import '../utils/bookmark_undo.dart';
import '../utils/formatters.dart';
import '../widgets/audio_handler_scope.dart';
import '../widgets/book_cover.dart';
import '../widgets/cast_picker_dialog.dart';
import '../widgets/chapter_list_sheet.dart';
import '../widgets/speed_dialog.dart';
import '../locator.dart';
import 'book_details_screen.dart';

// ── Sleep timer options ───────────────────────────────────────────────────────

typedef _TimerOpt = ({String label, Duration? duration, bool endOfChapter});

const List<_TimerOpt> _timerOpts = [
  (label: 'Off',            duration: null,                   endOfChapter: false),
  (label: '5 minutes',      duration: Duration(minutes: 5),   endOfChapter: false),
  (label: '10 minutes',     duration: Duration(minutes: 10),  endOfChapter: false),
  (label: '15 minutes',     duration: Duration(minutes: 15),  endOfChapter: false),
  (label: '30 minutes',     duration: Duration(minutes: 30),  endOfChapter: false),
  (label: '45 minutes',     duration: Duration(minutes: 45),  endOfChapter: false),
  (label: '60 minutes',     duration: Duration(minutes: 60),  endOfChapter: false),
  (label: 'End of chapter', duration: null,                   endOfChapter: true),
];

// ── Screen ────────────────────────────────────────────────────────────────────

class PlayerScreen extends StatefulWidget {
  final Audiobook book;
  const PlayerScreen({super.key, required this.book});

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  double _speed = 1.0;
  int _skipInterval = 30;

  // Sleep timer — state lives in the shared controller so it's visible
  // outside this screen (library AppBar, mini-player).
  final SleepTimerController _sleepCtrl = locator<SleepTimerController>();

  // Progress slider drag state
  bool _dragging = false;
  Duration _dragPosition = Duration.zero;

  // Chapter tracking — used for both UI display and "end of chapter" timer.
  // _currentChapterIndex drives the chapter label and chapter list highlight.
  // It is set synchronously after loadBook() completes (not from player.position
  // at build-time, which can be transiently zero during setAudioSources).
  int _currentChapterIndex = 0;
  int _lastChapterIndex = 0; // shadow copy used only by the sleep-timer logic
  StreamSubscription<int?>? _chapterSub;
  StreamSubscription<Duration>? _posSub; // M4B: tracks chapter changes via position

  late final KowhaiHandler _audioHandler;
  bool _didInit = false;

  // Error-state tracking — mirrors handler.errorStream so we can disable
  // controls + show a retry snackbar without StreamBuilder-wrapping everything.
  StreamSubscription<String?>? _errorSub;
  String? _currentError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_didInit) {
      _didInit = true;
      _audioHandler = AudioHandlerScope.of(context).audioHandler;
      _speed = _audioHandler.player.speed;
      _loadSkipInterval();
      _loadBook();
      // currentIndexStream fires when the active track changes.
      // For M4B books the index is always 0 (single file), so we must NOT
      // use it to drive _currentChapterIndex — _posSub handles that instead.
      // For multi-file books there are no embedded chapters, so the track
      // index IS the chapter index and _posSub is not subscribed.
      _chapterSub = _audioHandler.player.currentIndexStream.listen((idx) {
        if (idx == null || !mounted) return;
        if (widget.book.chapters.isEmpty && idx != _currentChapterIndex) {
          setState(() => _currentChapterIndex = idx);
        }
        if (idx != _lastChapterIndex) {
          _stopAtChapterEndIfArmed();
          setState(() => _lastChapterIndex = idx);
        }
      });

      // Sleep timer updates are consumed by a scoped ValueListenableBuilder
      // around the timer chip only (see _bottomRow) — no full-screen rebuilds.

      // Error stream → snackbar with retry. `null` clears any banner.
      _errorSub = _audioHandler.errorStream.listen(_onError);

      // M4B: derive chapter from position stream, but only setState when
      // the chapter index actually changes (avoids rebuilds every 200 ms).
      if (widget.book.chapters.isNotEmpty) {
        _posSub = _audioHandler.effectivePositionStream.listen((pos) {
          if (!mounted) return;
          final idx = widget.book.chapterIndexAt(pos);
          if (idx != _currentChapterIndex) {
            setState(() {
              _currentChapterIndex = idx;
              // Kept in step with the M4B path so the end-of-chapter guard
              // below can tell a genuine boundary crossing from the initial
              // sample.
              _lastChapterIndex = idx;
            });
          }
          // "End of chapter" has to be honoured here too. For M4B the track
          // index is always 0, so the check in _chapterSub never fires and
          // the feature silently did nothing for the app's primary format:
          // the chip showed "End of ch." and playback ran to the end of the
          // book.
          _stopAtChapterEndIfArmed(chapterIndex: idx);
        });
      }
    }
  }

  /// Pauses and disarms the sleep timer if "stop at end of chapter" is armed.
  ///
  /// Called from BOTH chapter-detection paths: the track-index stream (multi-
  /// file books) and the position stream (M4B). [chapterIndex] is passed only
  /// to let the M4B path skip the first sample, which reports the chapter the
  /// player restored INTO rather than a chapter boundary.
  void _stopAtChapterEndIfArmed({int? chapterIndex}) {
    if (!_sleepCtrl.stopAtChapterEnd.value) return;
    if (chapterIndex != null && chapterIndex == _lastChapterIndex) return;
    _audioHandler.pause();
    _cancelTimer();
  }

  Future<void> _loadBook() async {
    final isNew = _audioHandler.currentBook?.path != widget.book.path;
    if (isNew) setState(() { _lastChapterIndex = 0; _currentChapterIndex = 0; });
    await _audioHandler.loadBook(widget.book);
    // loadBook has now positioned the player (either restored from DB or left
    // in place for the same book). Read the correct chapter index now and push
    // it to state — this is the first reliable moment to do so.
    if (mounted) {
      final pos = _audioHandler.player.position;
      final idx = widget.book.chapters.isNotEmpty
          ? widget.book.chapterIndexAt(pos)
          : (_audioHandler.player.currentIndex ?? 0);
      setState(() => _currentChapterIndex = idx);
    }
  }

  @override
  void dispose() {
    _chapterSub?.cancel();
    _posSub?.cancel();
    _errorSub?.cancel();
    super.dispose();
  }

  // ── Error handling ─────────────────────────────────────────────────────────

  void _onError(String? message) {
    if (!mounted) return;
    setState(() => _currentError = message);
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (message == null) {
      messenger?.hideCurrentSnackBar();
      return;
    }
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
            label: 'Retry',
            onPressed: () => _audioHandler.retry(),
          ),
        ),
      );
  }

  // ── Sleep timer ─────────────────────────────────────────────────────────────

  void _setTimer(_TimerOpt opt) {
    if (opt.endOfChapter) {
      _sleepCtrl.setStopAtChapterEnd(true);
      return;
    }
    if (opt.duration == null) {
      _sleepCtrl.cancel();
      return;
    }
    _sleepCtrl.startTimed(opt.duration!, onFire: _audioHandler.pause);
  }

  void _cancelTimer() => _sleepCtrl.cancel();

  // ── Skip interval ────────────────────────────────────────────────────────────

  Future<void> _loadSkipInterval() async {
    final s = await locator<PreferencesService>().getSkipInterval();
    _audioHandler.updateSkipInterval(s);
    if (mounted) setState(() => _skipInterval = s);
  }

  IconData get _rewindIcon {
    switch (_skipInterval) {
      case 10: return Icons.replay_10_rounded;
      case 30: return Icons.replay_30_rounded;
      default: return Icons.replay_rounded;
    }
  }

  IconData? get _forwardIcon {
    switch (_skipInterval) {
      case 10: return Icons.forward_10_rounded;
      case 30: return Icons.forward_30_rounded;
      default: return null; // use mirrored replay icon
    }
  }

  // ── Speed ────────────────────────────────────────────────────────────────────

  void _showSpeedDialog() {
    showSpeedDialog(
      context: context,
      currentSpeed: _speed,
      audioHandler: _audioHandler,
    ).then((newSpeed) {
      // The sheet's route has just popped; the screen may be gone.
      if (!mounted) return;
      setState(() => _speed = newSpeed);
    });
  }

  // ── Custom sleep timer ────────────────────────────────────────────────────────

  Future<void> _showCustomTimerDialog() async {
    final result = await showCustomTimerDialog(context);
    if (result != null) {
      _setTimer((
        label: '$result min',
        duration: Duration(minutes: result),
        endOfChapter: false,
      ));
    }
  }

  // ── Sleep timer sheet ─────────────────────────────────────────────────────

  Future<void> _showSleepTimerSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        final theme = Theme.of(ctx);
        final maxHeight = MediaQuery.of(ctx).size.height * 0.75;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Sleep timer',
                        style: theme.textTheme.titleMedium),
                  ),
                ),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      ..._timerOpts.map((opt) {
                        final isActive = (opt.endOfChapter && _sleepCtrl.stopAtChapterEnd.value) ||
                            (!opt.endOfChapter && opt.duration == null && !_timerActive);
                        return ListTile(
                          title: Text(opt.label),
                          trailing: isActive
                              ? Icon(Icons.check_rounded,
                                  color: theme.colorScheme.primary)
                              : null,
                          onTap: () {
                            _setTimer(opt);
                            Navigator.pop(ctx);
                          },
                        );
                      }),
                      const Divider(height: 1),
                      ListTile(
                        title: const Text('Custom…'),
                        onTap: () async {
                          Navigator.pop(ctx);
                          await _showCustomTimerDialog();
                        },
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  String get _timerLabel {
    if (_sleepCtrl.stopAtChapterEnd.value) return 'End of ch.';
    final remaining = _sleepCtrl.remaining.value;
    if (remaining != null) return fmtHM(remaining);
    return 'Sleep';
  }

  bool get _timerActive => _sleepCtrl.isActive;

  Future<void> _showChapterList(BuildContext context) async {
    await showChapterListSheet(
      context: context,
      book: widget.book,
      currentChapterIndex: _currentChapterIndex,
      audioHandler: _audioHandler,
    );
  }

  // ── Bookmarks ─────────────────────────────────────────────────────────────

  Future<void> _showBookmarksSheet(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _BookmarksSheet(
        book: widget.book,
        audioHandler: _audioHandler,
        currentChapterIndex: _currentChapterIndex,
        onAddBookmark: () async {
          Navigator.pop(ctx);
          await _showAddBookmarkDialog(context);
          if (context.mounted) _showBookmarksSheet(context);
        },
      ),
    );
  }

  Future<void> _showAddBookmarkDialog(BuildContext context) async {
    final position = _audioHandler.effectivePosition;
    final chapterIndex = _currentChapterIndex;

    final nameCtrl = TextEditingController();
    final notesCtrl = TextEditingController();

    // These are locals in a plain async function, not a State, so nothing
    // else would ever dispose them. Every "Add bookmark" leaked two
    // controllers (text buffer + listener registrations).
    try {
      await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add bookmark'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              fmtHMSec(position),
              style: Theme.of(ctx).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(ctx).colorScheme.primary,
                  ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Name (optional)',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: notesCtrl,
              decoration: const InputDecoration(
                labelText: 'Notes (optional)',
                border: OutlineInputBorder(),
              ),
              textCapitalization: TextCapitalization.sentences,
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final label = nameCtrl.text.trim().isEmpty
                  ? 'Chapter ${chapterIndex + 1} — ${fmtHMSec(position)}'
                  : nameCtrl.text.trim();
              await locator<PositionService>().addBookmark(Bookmark(
                bookPath: widget.book.path,
                chapterIndex: chapterIndex,
                positionMs: position.inMilliseconds,
                label: label,
                notes: notesCtrl.text.trim().isEmpty
                    ? null
                    : notesCtrl.text.trim(),
                createdAt: DateTime.now().millisecondsSinceEpoch,
              ));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Save'),
          ),
        ],
      ),
      );
    } finally {
      nameCtrl.dispose();
      notesCtrl.dispose();
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final book = widget.book;
    final chapterCount = book.audioFiles.length;

    return Scaffold(
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: 'Bookmarks',
            icon: const Icon(Icons.bookmark_outline_rounded),
            onPressed: () => _showBookmarksSheet(context),
          ),
          IconButton(
            tooltip: 'Book details',
            icon: const Icon(Icons.info_outline_rounded),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => BookDetailsScreen(book: book)),
            ),
          ),
          StreamBuilder<GoogleCastSession?>(
            stream: GoogleCastSessionManager.instance.currentSessionStream,
            builder: (context, _) {
              final connected =
                  GoogleCastSessionManager.instance.connectionState ==
                  GoogleCastConnectState.connected;
              return IconButton(
                tooltip: connected ? 'Stop casting' : 'Cast',
                icon: Icon(connected ? Icons.cast_connected : Icons.cast),
                color: connected ? Theme.of(context).colorScheme.primary : null,
                onPressed: connected
                    ? GoogleCastSessionManager.instance.endSessionAndStopCasting
                    : () => showCastPicker(context),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            children: [
              const SizedBox(height: 12),
              // ── Cover ──
              Expanded(
                flex: 5,
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: BookCover(
                          book: widget.book,
                          iconSize: 80,
                          decodeSize: 1024),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // ── Title / author / chapter ──
              _infoSection(book, chapterCount, theme),
              const SizedBox(height: 12),
              // ── Progress slider ──
              _progressSection(book, theme),
              const SizedBox(height: 24), // breathing room where book-remaining row was
              // ── Playback controls ──
              _controlsSection(theme),
              const SizedBox(height: 24), // extra space below controls
              // ── Speed + timer ──
              _bottomRow(theme),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // ── Info section ───────────────────────────────────────────────────────────

  Widget _infoSection(Audiobook book, int chapterCount, ThemeData theme) {
    final isM4b = book.chapters.isNotEmpty;
    final totalChapters = isM4b ? book.chapters.length : chapterCount;
    final hasChapters = totalChapters > 1;

    String? chapterTitle(int currentIndex) {
      if (isM4b) return book.chapters[currentIndex].title;
      if (book.chapterNames.isNotEmpty &&
          currentIndex < book.chapterNames.length) {
        return book.chapterNames[currentIndex];
      }
      return null;
    }

    Widget chapterLabel(int currentIndex) => Semantics(
          button: hasChapters,
          label: hasChapters ? 'Open chapter list' : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: hasChapters ? () => _showChapterList(context) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        chapterTitle(currentIndex) != null
                            ? 'Ch. ${currentIndex + 1}/$totalChapters · ${chapterTitle(currentIndex)}'
                            : 'Chapter ${currentIndex + 1} of $totalChapters',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.primary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (hasChapters) ...[
                      const SizedBox(width: 2),
                      Icon(Icons.expand_more_rounded,
                          size: 16, color: theme.colorScheme.primary),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );

    return Column(children: [
      Text(
        book.title,
        style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
      ),
      if (book.author != null) ...[
        const SizedBox(height: 4),
        Text(
          book.author!,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
          ),
        ),
      ],
      if (hasChapters) ...[
        const SizedBox(height: 8),
        // _currentChapterIndex is kept up-to-date by stream subscriptions set up
        // in didChangeDependencies, and seeded synchronously after loadBook().
        // Using state directly avoids a one-frame flash to chapter 1 that occurred
        // when StreamBuilder initialData read player.position during setAudioSources.
        chapterLabel(_currentChapterIndex),
      ],
    ]);
  }

  // ── Progress section ───────────────────────────────────────────────────────

  Widget _progressSection(Audiobook book, ThemeData theme) {
    final isM4b = book.chapters.isNotEmpty;
    return StreamBuilder<Duration?>(
      stream: _audioHandler.effectiveDurationStream,
      initialData: _audioHandler.player.duration,
      builder: (_, durSnap) {
        // For multi-file books, just_audio reports per-file duration.
        // Use the book's total duration instead.
        final dur = (!isM4b && book.duration != null)
            ? book.duration!
            : (durSnap.data ?? Duration.zero);
        return StreamBuilder<Duration>(
          stream: _audioHandler.effectivePositionStream,
          initialData: _audioHandler.player.position,
          builder: (_, posSnap) {
            final rawPos = posSnap.data ?? Duration.zero;

            // For multi-file books, just_audio 0.10 reports per-file position.
            // Convert to global position so the slider and time labels are
            // correct across the whole book.
            final Duration displayed;
            if (!isM4b && book.chapterDurations.isNotEmpty) {
              final globalMs = calculateGlobalPosition(
                chapterIndex: _currentChapterIndex,
                chapterPosition: _dragging ? _dragPosition : rawPos,
                chapterDurations: book.chapterDurations,
              );
              displayed = Duration(milliseconds: globalMs);
            } else {
              displayed = _dragging ? _dragPosition : rawPos;
            }

            final maxMs = dur.inMilliseconds.toDouble();
            final value = maxMs > 0
                ? displayed.inMilliseconds.toDouble().clamp(0.0, maxMs)
                : 0.0;

            // Snap to whole seconds so both labels always tick together
            final displayedSec =
                Duration(seconds: displayed.inSeconds);

            // Chapter-scoped elapsed and remaining.
            // Use raw `displayed` (not second-snapped) for chapter lookup so we
            // don't land one chapter behind when position is just past a boundary
            // that doesn't fall on a whole second (e.g. chapters[4].start=1574007ms
            // but displayedSec=1574000ms would return chapter 3 for ~1 second).
            final Duration chapterElapsed;
            final Duration chapterRemaining;
            if (isM4b) {
              final chIdx = book.chapterIndexAt(displayed);
              final chStart = book.chapters[chIdx].start;
              final chEnd = (chIdx + 1 < book.chapters.length)
                  ? book.chapters[chIdx + 1].start
                  : dur;
              // Clamp elapsed to zero: displayedSec can be slightly before chStart
              // in the first sub-second after a seek to a non-second-aligned boundary.
              chapterElapsed = displayedSec > chStart
                  ? displayedSec - chStart
                  : Duration.zero;
              chapterRemaining = chEnd > displayedSec
                  ? chEnd - displayedSec
                  : Duration.zero;
            } else {
              // Multi-file: just_audio 0.10 exposes global position and total
              // duration via setAudioSources, so we compute chapter-relative
              // elapsed/remaining from chapterDurations + _currentChapterIndex.
              if (book.chapterDurations.isNotEmpty) {
                final chapStart = Duration(
                  milliseconds: calculateGlobalPosition(
                    chapterIndex: _currentChapterIndex,
                    chapterPosition: Duration.zero,
                    chapterDurations: book.chapterDurations,
                  ),
                );
                final chapDur = _currentChapterIndex < book.chapterDurations.length
                    ? book.chapterDurations[_currentChapterIndex]
                    : Duration.zero;
                final chapEnd = chapStart + chapDur;
                chapterElapsed =
                    displayedSec > chapStart ? displayedSec - chapStart : Duration.zero;
                chapterRemaining =
                    chapEnd > displayedSec ? chapEnd - displayedSec : Duration.zero;
              } else {
                // chapterDurations not populated — fall back to book-level times.
                chapterElapsed = displayedSec;
                chapterRemaining = dur - displayedSec;
              }
            }

            return Column(children: [
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
                ),
                child: Slider(
                  value: value,
                  min: 0,
                  max: maxMs > 0 ? maxMs : 1,
                  onChangeStart: (_) => setState(() => _dragging = true),
                  onChanged: (v) =>
                      setState(() => _dragPosition = Duration(milliseconds: v.toInt())),
                  onChangeEnd: (v) {
                    setState(() => _dragging = false);
                    final globalMs = v.toInt();
                    // For multi-file books, convert global position back to
                    // chapter index + per-file offset.
                    if (!isM4b && book.chapterDurations.isNotEmpty) {
                      int remaining = globalMs;
                      int idx = 0;
                      for (int i = 0; i < book.chapterDurations.length; i++) {
                        final chapMs = book.chapterDurations[i].inMilliseconds;
                        if (remaining < chapMs) {
                          idx = i;
                          break;
                        }
                        remaining -= chapMs;
                        idx = i + 1;
                      }
                      // num.clamp throws ArgumentError when lowerLimit >
                      // upperLimit, so an empty audioFiles list would crash
                      // here rather than clamp.
                      if (book.audioFiles.isNotEmpty) {
                        idx = idx.clamp(0, book.audioFiles.length - 1);
                        _audioHandler.player.seek(
                          Duration(milliseconds: remaining),
                          index: idx,
                        );
                      } else {
                        _audioHandler.seek(Duration(milliseconds: globalMs));
                      }
                    } else {
                      _audioHandler.seek(Duration(milliseconds: globalMs));
                    }
                  },
                ),
              ),
              // Times row: chapter elapsed · chapter remaining · book remaining
              // Book remaining is hidden on narrow screens to prevent overflow.
              LayoutBuilder(
                builder: (context, constraints) {
                  final bookRemaining = (book.duration != null &&
                          book.duration! > Duration.zero)
                      ? '${fmtHourMin(book.duration! - displayedSec)} left'
                      : null;
                  // ~200dp is enough to show all three labels comfortably.
                  final showBookRemaining =
                      bookRemaining != null && constraints.maxWidth >= 200;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(fmtHM(chapterElapsed),
                            style: theme.textTheme.bodySmall),
                        if (showBookRemaining)
                          Text(
                            bookRemaining,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                        Text('-${fmtHM(chapterRemaining)}',
                            style: theme.textTheme.bodySmall),
                      ],
                    ),
                  );
                },
              ),
            ]);
          },
        );
      },
    );
  }

  // ── Controls ───────────────────────────────────────────────────────────────

  Widget _controlsSection(ThemeData theme) {
    return StreamBuilder<PlaybackState>(
      stream: _audioHandler.playbackState,
      builder: (_, snap) {
        final state = snap.data;
        final playing = state?.playing ?? false;
        final errored = _currentError != null ||
            state?.processingState == AudioProcessingState.error;
        final busy = !errored &&
            (state?.processingState == AudioProcessingState.loading ||
                state?.processingState == AudioProcessingState.buffering);

        final primaryColor = errored
            ? theme.colorScheme.primary.withValues(alpha: 0.4)
            : theme.colorScheme.primary;

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _iconBtn(Icons.skip_previous_rounded, 34,
                errored ? null : _audioHandler.skipToPrevious,
                tooltip: 'Previous chapter'),
            _iconBtn(_rewindIcon, 34,
                errored ? null : _audioHandler.rewind,
                tooltip: 'Rewind ${_skipInterval}s'),
            // Central play/pause button (becomes a retry icon on error)
            Semantics(
              button: true,
              label: errored ? 'Retry' : (playing ? 'Pause' : 'Play'),
              child: GestureDetector(
                onTap: errored
                    ? _audioHandler.retry
                    : (playing ? _audioHandler.pause : _audioHandler.play),
                child: Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    color: primaryColor,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: busy
                        ? SizedBox(
                            width: 28, height: 28,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: theme.colorScheme.onPrimary))
                        : Icon(
                            errored
                                ? Icons.refresh_rounded
                                : (playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded),
                            size: 38,
                            color: theme.colorScheme.onPrimary,
                          ),
                  ),
                ),
              ),
            ),
            _forwardIcon != null
                ? _iconBtn(_forwardIcon!, 34,
                    errored ? null : _audioHandler.fastForward,
                    tooltip: 'Skip forward ${_skipInterval}s')
                : IconButton(
                    iconSize: 34,
                    tooltip: 'Skip forward ${_skipInterval}s',
                    icon: Transform.scale(
                      scaleX: -1,
                      child: const Icon(Icons.replay_rounded),
                    ),
                    onPressed: errored ? null : _audioHandler.fastForward,
                  ),
            _iconBtn(Icons.skip_next_rounded, 34,
                errored ? null : _audioHandler.skipToNext,
                tooltip: 'Next chapter'),
          ],
        );
      },
    );
  }

  Widget _iconBtn(IconData icon, double size, VoidCallback? onTap,
          {String? tooltip}) =>
      IconButton(
        iconSize: size,
        tooltip: tooltip,
        icon: Icon(icon),
        onPressed: onTap,
      );

  // ── Speed + timer row ──────────────────────────────────────────────────────

  Widget _bottomRow(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Speed
        Tooltip(
          message: 'Playback speed',
          child: Semantics(
            button: true,
            label: 'Playback speed: ${fmtSpeed(_speed)}',
            excludeSemantics: true,
            child: GestureDetector(
              onTap: _showSpeedDialog,
              child: _chip(
                icon: Icons.speed_rounded,
                label: (_speed - 1.0).abs() < 0.01 ? 'Speed' : fmtSpeed(_speed),
                active: (_speed - 1.0).abs() > 0.001,
                theme: theme,
              ),
            ),
          ),
        ),
        // Sleep timer — listens to the controller directly so the 1 Hz
        // countdown repaints only this chip, not the whole screen.
        ValueListenableBuilder<Duration?>(
          valueListenable: _sleepCtrl.remaining,
          builder: (context, _, __) =>
              ValueListenableBuilder<bool>(
                valueListenable: _sleepCtrl.stopAtChapterEnd,
                builder: (context, _, __) => Tooltip(
                  message: 'Sleep timer',
                  child: Semantics(
                    button: true,
                    label: 'Sleep timer: $_timerLabel',
                    excludeSemantics: true,
                    child: GestureDetector(
                      onTap: () => _showSleepTimerSheet(context),
                      child: _chip(
                        icon: Icons.timer_rounded,
                        label: _timerLabel,
                        active: _timerActive,
                        theme: theme,
                      ),
                    ),
                  ),
                ),
              ),
        ),
      ],
    );
  }

  Widget _chip({
    required IconData icon,
    required String label,
    required bool active,
    required ThemeData theme,
    bool showDropdown = true,
  }) {
    final color = active ? theme.colorScheme.primary : theme.colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: active
            ? theme.colorScheme.primary.withValues(alpha: 0.15)
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
        if (showDropdown) ...[
          const SizedBox(width: 4),
          Icon(Icons.arrow_drop_down, size: 16, color: color),
        ],
      ]),
    );
  }
}

// ── Bookmarks sheet ───────────────────────────────────────────────────────────────────

class _BookmarksSheet extends StatefulWidget {
  final Audiobook book;
  final KowhaiHandler audioHandler;
  final int currentChapterIndex;
  final VoidCallback onAddBookmark;

  const _BookmarksSheet({
    required this.book,
    required this.audioHandler,
    required this.currentChapterIndex,
    required this.onAddBookmark,
  });

  @override
  State<_BookmarksSheet> createState() => _BookmarksSheetState();
}

class _BookmarksSheetState extends State<_BookmarksSheet> {
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
    // See book_details_screen._delete: the item must leave the list within
    // the onDismissed frame or Dismissible asserts it is still in the tree.
    setState(() => _bookmarks?.removeWhere((b) => b.id == bookmark.id));
    await deleteBookmarkWithUndo(context, bookmark);
  }

  void _jumpTo(Bookmark bookmark) {
    final book = widget.book;
    final isM4b = book.chapters.isNotEmpty;
    if (isM4b) {
      widget.audioHandler
          .seek(Duration(milliseconds: bookmark.positionMs));
    } else {
      // Multi-file: seek to the start of the chapter file, then offset.
      // chapterIndex is persisted in the DB and restored verbatim. If the
      // book's files were removed or renamed since the bookmark was written,
      // it can exceed the loaded sequence, and just_audio's
      // seek(Duration, index:) asserts on that. Clamped to what exists.
      final maxIndex = widget.audioHandler.player.sequence.length - 1;
      if (maxIndex < 0) {
        Navigator.pop(context);
        return;
      }
      final index = bookmark.chapterIndex.clamp(0, maxIndex);
      final startMs = _chapterStartMs(book, index);
      widget.audioHandler.player.seek(
        Duration(milliseconds: (bookmark.positionMs - startMs)
            .clamp(0, Duration(milliseconds: bookmark.positionMs).inMilliseconds)),
        index: index,
      );
    }
    widget.audioHandler.play();
    Navigator.pop(context);
  }

  /// Returns the global start position in ms of [chapterIndex] for multi-file books.
  int _chapterStartMs(Audiobook book, int chapterIndex) =>
      calculateGlobalPosition(
        chapterIndex: chapterIndex,
        chapterPosition: Duration.zero,
        chapterDurations: book.chapterDurations,
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bookmarks = _bookmarks;

    return DraggableScrollableSheet(
      initialChildSize: 0.5,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      expand: false,
      builder: (ctx, scrollCtrl) {
        return Column(
          children: [
            Padding(
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
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
              child: Row(
                children: [
                  Text('Bookmarks',
                      style: theme.textTheme.titleMedium),
                  const Spacer(),
                  TextButton.icon(
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('Add'),
                    onPressed: widget.onAddBookmark,
                  ),
                ],
              ),
            ),
            Expanded(
              child: bookmarks == null
                  ? const Center(child: CircularProgressIndicator())
                  : bookmarks.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.bookmark_outline_rounded,
                                    size: 48,
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.3)),
                                const SizedBox(height: 12),
                                Text('No bookmarks yet',
                                    style: theme.textTheme.bodyMedium
                                        ?.copyWith(
                                            color: theme.colorScheme.onSurface
                                                .withValues(alpha: 0.5))),
                              ],
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: scrollCtrl,
                          itemCount: bookmarks.length,
                          itemBuilder: (ctx, i) {
                            final bm = bookmarks[i];
                            return Dismissible(
                              key: ValueKey(bm.id),
                              direction: DismissDirection.endToStart,
                              background: Container(
                                alignment: Alignment.centerRight,
                                padding:
                                    const EdgeInsets.only(right: 20),
                                color: theme.colorScheme.errorContainer,
                                child: Icon(
                                  Icons.delete_outline_rounded,
                                  color: theme.colorScheme.onErrorContainer,
                                ),
                              ),
                              onDismissed: (_) => _delete(bm),
                              child: ListTile(
                                leading: Icon(
                                  Icons.bookmark_rounded,
                                  color: theme.colorScheme.primary,
                                ),
                                title: Text(
                                  bm.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: bm.notes != null
                                    ? Text(
                                        bm.notes!,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      )
                                    : null,
                                trailing: Text(
                                  fmtHMSec(Duration(
                                      milliseconds: bm.positionMs)),
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.55),
                                  ),
                                ),
                                onTap: () => _jumpTo(bm),
                              ),
                            );
                          },
                        ),
            ),
          ],
        );
      },
    );
  }
}

