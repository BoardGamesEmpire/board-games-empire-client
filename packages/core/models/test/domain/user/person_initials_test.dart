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

    // On web, toUpperCase is JavaScript's, which maps ß to SS, ﬁ to FI and
    // ŉ to ʼN, where the VM leaves each as it is. Uppercased whole, 'ß Foo'
    // gave three letters there.
    test('a letter whose capital is more than one letter stays as written', () {
      expect(personInitials('ß Foo'), 'ßF');
      expect(personInitials('ﬁona'), 'ﬁ');
      expect(personInitials('ŉ x'), 'ŉX');
    });

    test('never more than two graphemes, never a lone surrogate', () {
      const pieces = <String>[
        'a',
        'Z',
        'ß',
        'ﬁ',
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
