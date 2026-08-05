import 'package:test/test.dart';
import 'package:models/domain.dart';

void main() {
  group('CreateHouseholdOperation', () {
    test('type discriminator is create_household', () {
      expect(CreateHouseholdOperation.type, equals('create_household'));
    });

    test('toJson omits null optional fields', () {
      const op = CreateHouseholdOperation(
        localId: 'hh_local_1',
        name: 'Game Night HQ',
      );

      final json = op.toJson();
      expect(json['type'], equals('create_household'));
      expect(json['local_id'], equals('hh_local_1'));
      expect(json['name'], equals('Game Night HQ'));
      expect(json.containsKey('description'), isFalse);
      expect(json.containsKey('image'), isFalse);
      expect(json.containsKey('language'), isFalse);
      expect(json.containsKey('visibility'), isFalse);
    });

    test('toJson includes optional fields when set', () {
      const op = CreateHouseholdOperation(
        localId: 'hh_local_1',
        name: 'Game Night HQ',
        description: 'Where we play',
        image: 'https://example.test/hh.png',
        language: 'pt-BR',
        visibility: 'Friends',
      );

      final json = op.toJson();
      expect(json['description'], equals('Where we play'));
      expect(json['image'], equals('https://example.test/hh.png'));
      expect(json['language'], equals('pt-BR'));
      expect(json['visibility'], equals('Friends'));
    });

    test('round-trips through fromJson preserving all fields', () {
      const op = CreateHouseholdOperation(
        localId: 'hh_local_1',
        name: 'Game Night HQ',
        description: 'Where we play',
        image: 'https://example.test/hh.png',
        language: 'pt-BR',
        visibility: 'Friends',
      );

      final round = CreateHouseholdOperation.fromJson(op.toJson());
      expect(round.localId, equals('hh_local_1'));
      expect(round.name, equals('Game Night HQ'));
      expect(round.description, equals('Where we play'));
      expect(round.image, equals('https://example.test/hh.png'));
      expect(round.language, equals('pt-BR'));
      expect(round.visibility, equals('Friends'));
    });

    test('optional fields survive a round-trip as null', () {
      const op = CreateHouseholdOperation(
        localId: 'hh_local_1',
        name: 'Game Night HQ',
      );

      final round = CreateHouseholdOperation.fromJson(op.toJson());
      expect(round.description, isNull);
      expect(round.image, isNull);
      expect(round.language, isNull);
      expect(round.visibility, isNull);
    });

    test('serialized string round-trips via SyncOperation.deserialize', () {
      const op = CreateHouseholdOperation(
        localId: 'hh_local_1',
        name: 'Game Night HQ',
      );

      final decoded = SyncOperation.deserialize(op.serialized);
      expect(decoded, isA<CreateHouseholdOperation>());
      final typed = decoded as CreateHouseholdOperation;
      expect(typed.localId, equals('hh_local_1'));
      expect(typed.name, equals('Game Night HQ'));
    });
  });

  group('SyncOperation.fromJson dispatch', () {
    test('dispatches create_household to CreateHouseholdOperation', () {
      final op = SyncOperation.fromJson(const {
        'type': 'create_household',
        'local_id': 'hh_local_1',
        'name': 'Game Night HQ',
      });
      expect(op, isA<CreateHouseholdOperation>());
    });

    test('still dispatches the existing collection ops', () {
      final add = SyncOperation.fromJson(const {
        'type': 'add_to_collection',
        'local_id': 'col_1',
        'platform_game_id': 'pg_1',
        'medium': 'Physical',
        'quantity': 1,
      });
      expect(add, isA<AddToCollectionOperation>());
    });

    test('throws FormatException on an unknown type', () {
      expect(
        () => SyncOperation.fromJson(const {'type': 'not_a_real_op'}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
