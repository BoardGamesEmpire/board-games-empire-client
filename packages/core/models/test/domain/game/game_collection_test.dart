import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

DateTime get _now => DateTime.parse('2024-01-15T10:30:00Z');

GameCollection _make({
  GameMedium medium = GameMedium.physical,
  int quantity = 1,
  bool isDirty = false,
  bool isLocalOnly = false,
  DateTime? deletedAt,
  String? releaseId,
}) => GameCollection(
  id: 'col_1',
  userId: 'user_1',
  platformGameId: 'pg_1',
  medium: medium,
  quantity: quantity,
  isDirty: isDirty,
  isLocalOnly: isLocalOnly,
  deletedAt: deletedAt,
  releaseId: releaseId,
  createdAt: _now,
  updatedAt: _now,
);

void main() {
  group('GameCollection', () {
    test('defaults: non-deleted, non-dirty, quantity 1, no releaseId', () {
      final col = _make();
      expect(col.isDirty, isFalse);
      expect(col.isLocalOnly, isFalse);
      expect(col.isDeleted, isFalse);
      expect(col.quantity, equals(1));
      expect(col.releaseId, isNull);
      expect(col.deletedAt, isNull);
    });

    group('isOwned', () {
      test('true when quantity > 0 and not deleted', () {
        expect(_make(quantity: 2).isOwned, isTrue);
      });
      test('false when quantity == 0 even if not deleted', () {
        expect(_make(quantity: 0).isOwned, isFalse);
      });
      test('false when tombstoned even if quantity > 0', () {
        expect(_make(quantity: 1, deletedAt: _now).isOwned, isFalse);
      });
    });

    test('hasFavorited reflects the favorite flag explicitly', () {
      final none = _make();
      expect(none.hasFavorited, isFalse, reason: 'null favorite ≠ true');
      expect(none.copyWith(favorite: true).hasFavorited, isTrue);
      expect(none.copyWith(favorite: false).hasFavorited, isFalse);
    });

    test('serializes deletedAt and releaseId with camelCase keys', () {
      final col = _make(deletedAt: _now, releaseId: 'rel_42');
      final json = col.toJson();

      expect(json['deletedAt'], equals(_now.toIso8601String()));
      expect(json['releaseId'], equals('rel_42'));
    });

    test('round-trips with all fields populated', () {
      final col = GameCollection(
        id: 'col_2',
        userId: 'user_2',
        platformGameId: 'pg_2',
        medium: GameMedium.digital,
        releaseId: 'rel_2',
        quantity: 3,
        rating: 8,
        playCount: 12,
        playAgain: true,
        favorite: true,
        comment: 'great game',
        lastPlayed: _now,
        lastUpdated: _now,
        isDirty: true,
        isLocalOnly: false,
        deletedAt: null,
        createdAt: _now,
        updatedAt: _now,
      );

      final round = GameCollection.fromJson(col.toJson());
      expect(round, equals(col));
    });

    test('isDeleted is true iff deletedAt is non-null', () {
      expect(_make().isDeleted, isFalse);
      expect(_make(deletedAt: _now).isDeleted, isTrue);
    });
  });
}
