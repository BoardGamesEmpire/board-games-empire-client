import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  group('GameSearchRange', () {
    test('a range with neither bound does not narrow, whatever '
        'includeUnknown says', () {
      expect(const GameSearchRange().narrows, isFalse);
      expect(const GameSearchRange(includeUnknown: true).narrows, isFalse);
    });

    test('a range with one bound narrows', () {
      expect(const GameSearchRange(min: 3).narrows, isTrue);
      expect(const GameSearchRange(max: 3).narrows, isTrue);
      expect(const GameSearchRange(min: 0).narrows, isTrue);
    });

    test('a range is reversed only when both bounds are set and '
        'min > max', () {
      expect(const GameSearchRange(min: 5, max: 3).isReversed, isTrue);
      expect(const GameSearchRange(min: 3, max: 3).isReversed, isFalse);
      expect(const GameSearchRange(min: 5).isReversed, isFalse);
      expect(const GameSearchRange(max: 3).isReversed, isFalse);
    });
  });

  group('GameSearchFilter', () {
    test('the empty filter does not narrow, and equals a filter built from '
        'empty sets', () {
      const empty = GameSearchFilter();
      // Built at run time, so the sets are not the const defaults.
      final built = GameSearchFilter(
        contentTypes: <ContentType>{},
        platformTypes: <PlatformType>{},
      );

      expect(empty.narrows, isFalse);
      expect(built, empty);
      expect(built.hashCode, empty.hashCode);
    });

    test('any one axis makes the filter narrow', () {
      const narrowing = [
        GameSearchFilter(contentTypes: {ContentType.expansion}),
        GameSearchFilter(platformTypes: {PlatformType.pc}),
        GameSearchFilter(publishYear: GameSearchRange(min: -3000)),
        GameSearchFilter(playerCount: GameSearchRange(max: 4)),
        GameSearchFilter(playTime: GameSearchRange(min: 0)),
      ];

      for (final filter in narrowing) {
        expect(filter.narrows, isTrue, reason: '$filter');
      }
    });

    test('a range that keeps unknown values but has no bound does not make '
        'the filter narrow', () {
      const filter = GameSearchFilter(
        publishYear: GameSearchRange(includeUnknown: true),
      );

      expect(filter.narrows, isFalse);
    });
  });
}
