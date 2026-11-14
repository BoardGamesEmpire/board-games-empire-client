import 'dart:math';

import 'package:characters/characters.dart';
import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  group('personInitials', () {
    test('null, empty and spaces give null', () {
      expect(personInitials(null), isNull);
      expect(personInitials(''), isNull);
      expect(personInitials('   '), isNull);
    });

    test('two words give both initials', () {
      expect(personInitials('Ada Lovelace'), 'AL');
    });

    test('three words use the first and last', () {
      expect(personInitials('Ada King Lovelace'), 'AL');
    });

    test('one word gives one initial', () {
      expect(personInitials('ada'), 'A');
    });

    test('a decomposed accent stays with its letter (#349)', () {
      expect(personInitials('e\u{301}va'), 'E\u{301}');
    });

    test('a ZWJ sequence stays whole', () {
      expect(
        personInitials('\u{1F469}\u{200D}\u{1F4BB} Dev'),
        '\u{1F469}\u{200D}\u{1F4BB}D',
      );
    });

    test('a supplementary-plane letter is never split', () {
      expect(personInitials('\u{10437}x'), '\u{1040F}');
    });

    test('never more than two graphemes, never a lone surrogate', () {
      const pieces = <String>[
        'a',
        'Z',
        '\u{E9}',
        '\u{10437}',
        '\u{1F600}',
        '\u{301}',
        '\u{200D}',
        '\u{1F469}\u{200D}\u{1F4BB}',
        ' ',
        '  ',
      ];
      final random = Random(349);
      for (var i = 0; i < 200; i++) {
        final input = [
          for (var n = random.nextInt(8) + 1; n > 0; n--)
            pieces[random.nextInt(pieces.length)],
        ].join();
        final result = personInitials(input);
        if (result == null) continue;
        expect(
          result.characters.length,
          lessThanOrEqualTo(2),
          reason: 'for ${input.runes.toList()}',
        );
        expect(
          result.runes.every((r) => r < 0xD800 || r > 0xDFFF),
          isTrue,
          reason: 'lone surrogate for ${input.runes.toList()}',
        );
      }
    });
  });
}
