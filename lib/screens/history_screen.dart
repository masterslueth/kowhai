import 'package:flutter/material.dart';
import '../models/audiobook.dart';
import '../services/position_service.dart';
import '../widgets/book_cover.dart';
import 'player_screen.dart';
import '../locator.dart';

class HistoryScreen extends StatefulWidget {
  final List<Audiobook> books;
  const HistoryScreen({super.key, required this.books});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<_HistoryEntry>? _entries;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final positions = await locator<PositionService>().getAllPositions();
    final entries = <_HistoryEntry>[];
    for (final p in positions) {
      final book =
          widget.books.where((b) => b.path == p.bookPath).firstOrNull;
      if (book == null) continue; // book removed from library
      final pct = p.totalDurationMs > 0
          ? (p.globalPositionMs / p.totalDurationMs).clamp(0.0, 1.0)
          : 0.0;
      entries.add((book: book, pct: pct, updatedAt: p.updatedAt));
    }
    if (!mounted) return;
    setState(() => _entries = entries);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('History')),
      body: _entries == null
          ? const Center(child: CircularProgressIndicator())
          : _entries!.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No playback history yet.\nStart listening to a book!',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _entries!.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 76),
                  itemBuilder: (context, i) =>
                      _tile(context, theme, _entries![i]),
                ),
    );
  }

  Widget _tile(
      BuildContext context, ThemeData theme, _HistoryEntry entry) {
    final book = entry.book;
    final pct = entry.pct;
    final dateLabel = _relativeDate(entry.updatedAt);

    return ListTile(
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 52,
          height: 52,
          child: BookCover(book: book, iconSize: 26, decodeSize: 160),
        ),
      ),
      title: Text(
        book.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 4,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${(pct * 100).round()}% complete',
                style: theme.textTheme.bodySmall,
              ),
              Text(
                dateLabel,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.55)),
              ),
            ],
          ),
        ],
      ),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PlayerScreen(book: book)),
      ),
    );
  }

  String _relativeDate(int epochMs) {
    final then = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final now = DateTime.now();
    final diff = now.difference(then);
    if (diff.inDays == 0) return 'Today';
    if (diff.inDays == 1) return 'Yesterday';
    if (diff.inDays < 7) return '${diff.inDays} days ago';
    final months = const [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[then.month - 1]} ${then.day}';
  }
}

typedef _HistoryEntry = ({Audiobook book, double pct, int updatedAt});
