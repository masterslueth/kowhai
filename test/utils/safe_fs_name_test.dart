import 'package:flutter_test/flutter_test.dart';
import 'package:kowhai/utils/safe_fs_name.dart';

void main() {
  group('safeFsName', () {
    test('passes through ordinary names unchanged', () {
      expect(safeFsName('The Way of Kings'), 'The Way of Kings');
      expect(safeFsName('book-part1.mp3'), 'book-part1.mp3');
    });

    test('replaces path separators so the name cannot escape its directory', () {
      expect(safeFsName('a/b/c'), 'a_b_c');
      expect(safeFsName(r'a\b\c'), 'a_b_c');
      // Traversal attempt collapses to a flat, inert name.
      expect(safeFsName('../../etc/passwd'), '.._.._etc_passwd');
    });

    test('neutralises traversal-only names', () {
      final result = safeFsName('..');
      expect(result, isNot('..'));
      expect(result, isNot(contains('/')));
    });

    test('strips control characters and collapses whitespace', () {
      expect(safeFsName('a\x00b\x1fc'), 'abc');
      expect(safeFsName('a \t b   c'), 'a b c');
    });

    test('removes trailing dots and spaces (Windows)', () {
      expect(safeFsName('name...'), 'name');
      expect(safeFsName('name  '), 'name');
    });

    test('dot-only names collapse to underscore', () {
      expect(safeFsName('..'), '_');
      expect(safeFsName('.'), '_');
      expect(safeFsName(''), '_');
    });

    test('prefixes Windows reserved device names', () {
      expect(safeFsName('CON'), '_CON');
      expect(safeFsName('nul.txt'), '_nul.txt');
      expect(safeFsName('com1'), '_com1');
      // Not reserved
      expect(safeFsName('console'), 'console');
    });

    test('caps length while preserving extension', () {
      final long = '${'a' * 120}.mp3';
      final result = safeFsName(long);
      expect(result.length, 100);
      expect(result.endsWith('.mp3'), isTrue);
    });

    test('caps length when the extension itself is longer than the budget', () {
      // Regression: a naive `maxLength - ext.length` goes negative here and
      // threw RangeError, so a hostile Drive filename crashed the app.
      final hostile = 'chapter.${'a' * 200}';
      final result = safeFsName(hostile);
      expect(result.length, lessThanOrEqualTo(100));
      expect(result, isNot(contains('..')));
    });

    test('does not end a truncated name with a dot', () {
      // A slice landing on '.' produces a hidden/illegal filesystem name.
      expect(safeFsName('a.b', maxLength: 2), 'a');
      final dotted = 'a.${'b' * 200}';
      expect(safeFsName(dotted).endsWith('.'), isFalse);
    });

    test('truncation never yields an empty name', () {
      expect(safeFsName('a.${'b' * 200}'), isNotEmpty);
      expect(safeFsName('a' * 500), isNotEmpty);
    });

    test('handles unicode names without mangling', () {
      const name = 'Kāi Tahu — Te Reo (audiobook)';
      expect(safeFsName(name), name);
    });
  });
}
