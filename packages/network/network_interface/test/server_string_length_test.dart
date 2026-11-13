import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

// The expected lengths are what the server's validator answers for the same
// text: class-validator's MaxLength, through validator.js's isLength.
void main() {
  group('serverStringLength', () {
    test('counts plain text by code unit', () {
      expect(serverStringLength('a'), 1);
      expect(serverStringLength(''), 0);
    });

    test('counts a surrogate pair once', () {
      expect(serverStringLength('\u{1F600}'), 1);
    });

    test('counts a presentation sequence once', () {
      expect(serverStringLength('\u{270C}\u{FE0F}'), 1);
    });

    test('counts a surrogate pair and its presentation selector once', () {
      expect(serverStringLength('\u{1F44D}\u{FE0F}'), 1);
    });

    test('counts a lone surrogate as one code unit', () {
      expect(serverStringLength('\u{D800}'), 1);
      expect(serverStringLength('\u{DC00}'), 1);
      expect(serverStringLength('\u{D83D}a'), 2);
      expect(serverStringLength('\u{DC00}\u{D800}'), 2);
    });

    test('counts a trailing U+FE0F with the code unit before it', () {
      expect(serverStringLength('ab\u{FE0F}'), 2);
    });

    test('counts a U+FE0F with nothing before it as one code unit', () {
      expect(serverStringLength('\u{FE0F}'), 1);
      expect(serverStringLength('\u{FE0E}'), 1);
    });

    test('counts only the first of consecutive variation selectors', () {
      expect(serverStringLength('\u{270C}\u{FE0F}\u{FE0F}'), 2);
      expect(serverStringLength('\u{270C}\u{FE0E}\u{FE0F}'), 2);
      expect(serverStringLength('a\u{FE0F}\u{FE0F}\u{FE0F}'), 3);
      expect(serverStringLength('\u{FE0F}\u{FE0F}'), 2);
    });
  });
}
