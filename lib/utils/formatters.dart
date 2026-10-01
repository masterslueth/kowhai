// ── Pure helpers (testable) ───────────────────────────────────────────────────

/// Sums completed chapter durations plus [chapterPosition] to produce a
/// book-wide elapsed position in milliseconds.
int calculateGlobalPosition({
  required int chapterIndex,
  required Duration chapterPosition,
  required List<Duration> chapterDurations,
}) {
  int offset = 0;
  for (int i = 0; i < chapterIndex && i < chapterDurations.length; i++) {
    offset += chapterDurations[i].inMilliseconds;
  }
  return offset + chapterPosition.inMilliseconds;
}

/// Inverse of [calculateGlobalPosition]: maps a book-wide elapsed position
/// back to a (chapterIndex, offset-within-chapter) pair.
///
/// Overshoot past the last chapter clamps to the end of the final chapter.
/// With an empty [chapterDurations] list the whole offset lands on chapter 0
/// (mirroring calculateGlobalPosition's fallback). Durations that changed
/// between export and import make the remap approximate by nature.
({int chapterIndex, Duration position}) globalToChapterPosition(
    int globalMs, List<Duration> chapterDurations) {
  if (globalMs <= 0) return (chapterIndex: 0, position: Duration.zero);
  var remaining = globalMs;
  for (int i = 0; i < chapterDurations.length; i++) {
    final len = chapterDurations[i].inMilliseconds;
    if (remaining < len || i == chapterDurations.length - 1) {
      // Clamp to the chapter length so overshoot (stale/changed durations,
      // truncated re-encodes) never seeks past the file's end on resume.
      // A zero-length chapter must collapse to 0: the `len > 0` guard
      // previously skipped the clamp entirely and returned the full
      // unconsumed `remaining`, i.e. a position past the end of the file it
      // was attributed to. readMetadataChunk emits zero for every
      // unreadable track, so this is not hypothetical.
      final posMs = remaining > len ? len : remaining;
      return (chapterIndex: i, position: Duration(milliseconds: posMs));
    }
    remaining -= len;
  }
  return (chapterIndex: 0, position: Duration(milliseconds: globalMs));
}

/// Human-readable byte size string (B / KB / MB / GB).
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

/// Formats a speed value as e.g. "1.0×", "1.25×", "0.75×".
/// Values divisible by 0.1 get one decimal; others get two.
String fmtSpeed(double s) {
  final str = s.toStringAsFixed(2);
  return '${str.endsWith('0') ? s.toStringAsFixed(1) : str}×';
}

/// Formats a duration as `Xh Ym` (e.g. "2h 30m") or just `Ym` when under an hour.
/// Negative durations are clamped to zero. Used in book cards and detail views.
String fmtHourMin(Duration d) {
  if (d < Duration.zero) d = Duration.zero;
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return h > 0 ? '${h}h ${m}m' : '${m}m';
}

/// Formats a duration as `H:MM:SS` (if ≥ 1 hour) or `MM:SS`.
/// Negative durations are clamped to zero.
String fmtHM(Duration d) {
  if (d < Duration.zero) d = Duration.zero;
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// Formats a duration always including hours: `H:MM:SS`.
/// Used for bookmark timestamps so the format is consistent.
String fmtHMSec(Duration d) {
  if (d < Duration.zero) d = Duration.zero;
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}
