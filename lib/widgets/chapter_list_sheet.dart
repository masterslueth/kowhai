import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../models/audiobook.dart';
import '../services/audio_handler.dart';
import '../utils/formatters.dart';

/// Shows a draggable bottom sheet listing all chapters for [book].
///
/// Tapping a chapter seeks to it and pops the sheet.
Future<void> showChapterListSheet({
  required BuildContext context,
  required Audiobook book,
  required int currentChapterIndex,
  required KowhaiHandler audioHandler,
}) async {
  final isM4b = book.chapters.isNotEmpty;
  final chapCount = isM4b ? book.chapters.length : book.audioFiles.length;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) {
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
                    color: Theme.of(ctx).colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'Chapters',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
              ),
              Expanded(
                child: isM4b
                    ? _chapterListView(
                        context: ctx,
                        scrollCtrl: scrollCtrl,
                        count: chapCount,
                        currentIndex: currentChapterIndex,
                        title: (i) => book.chapters[i].title,
                        duration: (i) {
                          final start = book.chapters[i].start;
                          final end = i + 1 < book.chapters.length
                              ? book.chapters[i + 1].start
                              : (book.duration ?? Duration.zero);
                          return end > start ? end - start : null;
                        },
                        onTap: (i) {
                          audioHandler.seek(book.chapters[i].start);
                          Navigator.of(context).pop();
                        },
                      )
                    : _chapterListView(
                        context: ctx,
                        scrollCtrl: scrollCtrl,
                        count: chapCount,
                        currentIndex: currentChapterIndex,
                        title: (i) {
                          // chapCount is derived from audioFiles.length while
                          // the name list is chapterNames, so the two can
                          // disagree; bounds-check before indexing rather than
                          // trusting the invariant to hold.
                          if (i < book.chapterNames.length) {
                            return book.chapterNames[i];
                          }
                          if (i < book.audioFiles.length) {
                            return p.basenameWithoutExtension(book.audioFiles[i]);
                          }
                          return 'Chapter ${i + 1}';
                        },
                        duration: (i) => i < book.chapterDurations.length
                            ? book.chapterDurations[i]
                            : null,
                        onTap: (i) {
                          audioHandler.player
                              .seek(Duration.zero, index: i);
                          Navigator.of(context).pop();
                        },
                      ),
              ),
            ],
          );
        },
      );
    },
  );
}

Widget _chapterListView({
  required BuildContext context,
  required ScrollController scrollCtrl,
  required int count,
  required int currentIndex,
  required String Function(int) title,
  required void Function(int) onTap,
  Duration? Function(int)? duration,
}) {
  final theme = Theme.of(context);
  return ListView.builder(
    controller: scrollCtrl,
    itemCount: count,
    itemBuilder: (ctx, i) {
      final isCurrent = i == currentIndex;
      final dur = duration?.call(i);
      return ListTile(
        leading: isCurrent
            ? Icon(Icons.volume_up_rounded,
                color: theme.colorScheme.primary, size: 20)
            : Text(
                '${i + 1}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
        title: Text(
          title(i),
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: isCurrent ? FontWeight.bold : null,
            color: isCurrent ? theme.colorScheme.primary : null,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: dur != null && dur > Duration.zero
            ? Text(
                fmtHM(dur),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
                ),
              )
            : null,
        onTap: () => onTap(i),
      );
    },
  );
}
