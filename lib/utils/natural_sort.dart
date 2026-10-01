/// Natural sort comparator for strings containing numbers.
///
/// Splits strings into numeric and non-numeric segments, comparing numbers
/// numerically and text lexicographically. This ensures "2.mp3" < "10.mp3"
/// instead of the default string sort where "10.mp3" < "2.mp3".
///
/// Example:
/// ```dart
/// final files = ['track2.mp3', 'track10.mp3', 'track1.mp3'];
/// files.sort((a, b) => naturalCompare(a, b));
/// // Result: ['track1.mp3', 'track2.mp3', 'track10.mp3']
/// ```
int naturalCompare(String a, String b) {
  final aLow = a.toLowerCase();
  final bLow = b.toLowerCase();
  final aSegments = _splitNatural(aLow);
  final bSegments = _splitNatural(bLow);
  final len = aSegments.length < bSegments.length ? aSegments.length : bSegments.length;

  for (int i = 0; i < len; i++) {
    final aS = aSegments[i];
    final bS = bSegments[i];
    final aNum = _parseNumeric(aS);
    final bNum = _parseNumeric(bS);

    int cmp;
    if (aNum != null && bNum != null) {
      cmp = aNum.compareTo(bNum);
    } else if (aNum != null || bNum != null) {
      // One side is a (possibly clamped) number and the other is text. Text
      // sorts after any number, so the comparison stays a total order even
      // where both values are unclamped.
      cmp = aNum != null ? -1 : 1;
    } else {
      cmp = aS.compareTo(bS);
    }

    if (cmp != 0) return cmp;
  }

  return aSegments.length.compareTo(bSegments.length);
}

/// Parses a pure-digit segment for numeric comparison, saturating at [_maxInt]
/// rather than returning null.
///
/// `int.tryParse` returns null once a run of digits exceeds 64 bits, which sent
/// both operands down the lexicographic branch: "99999999999999999999" then
/// sorted BEFORE "1000000000000000000" - exactly backwards. Saturating keeps
/// both sides numeric so the ordering is correct. The cap is far above any
/// real chapter/file number, so the only segments it affects are the ones
/// where lexicographic order was simply wrong.
int? _parseNumeric(String s) {
  if (s.isEmpty) return null;
  var acc = 0;
  for (var i = 0; i < s.length; i++) {
    final digit = s.codeUnitAt(i) - 0x30;
    if (digit < 0 || digit > 9) return null; // not a pure digit run
    if (acc > (_maxInt - digit) ~/ 10) return _maxInt;
    acc = acc * 10 + digit;
  }
  return acc;
}

/// Saturated ceiling for [naturalCompare]'s numeric segments.
const int _maxInt = 0x3FFFFFFFFFFFFFFF;

/// Splits a string into numeric and non-numeric segments.
///
/// Example: "track2a10" → ["track", "2", "a", "10"]
List<String> _splitNatural(String s) {
  final segments = <String>[];
  final re = RegExp(r'(\d+|\D+)');
  for (final m in re.allMatches(s)) {
    segments.add(m.group(0)!);
  }
  return segments;
}
