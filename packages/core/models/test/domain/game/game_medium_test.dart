import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

GameCollection _makeCollection({required GameMedium medium}) {
  final now = DateTime.parse('2024-01-15T10:30:00Z');
  return GameCollection(
    id: 'col_1',
    userId: 'user_1',
    platformGameId: 'pg_1',
    medium: medium,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('GameMedium', () {
    test('every Dart value round-trips through GameCollection.medium', () {
      for (final value in GameMedium.values) {
        final col = _makeCollection(medium: value);
        final round = GameCollection.fromJson(col.toJson());
        expect(round.medium, equals(value));
      }
    });

    test('wire format is PascalCase', () {
      expect(
        _makeCollection(medium: GameMedium.physical).toJson()['medium'],
        equals('Physical'),
      );
      expect(
        _makeCollection(medium: GameMedium.digital).toJson()['medium'],
        equals('Digital'),
      );
    });

    test('every Prisma GameMedium value has a Dart binding', () {
      const serverValues = <String>['Physical', 'Digital'];
      for (final wireValue in serverValues) {
        final json = _makeCollection(medium: GameMedium.physical).toJson();
        json['medium'] = wireValue;
        expect(
          () => GameCollection.fromJson(json),
          returnsNormally,
          reason: 'server value "$wireValue" must deserialize',
        );
      }
    });

    test('wire helpers agree with @JsonValue mappings', () {
      for (final value in GameMedium.values) {
        final viaJsonValue =
            _makeCollection(medium: value).toJson()['medium'] as String;
        expect(value.toWire(), equals(viaJsonValue));
        expect(GameMedium.fromWire(viaJsonValue), equals(value));
      }
    });

    test('fromWire throws on unrecognized value', () {
      expect(
        () => GameMedium.fromWire('Holographic'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
