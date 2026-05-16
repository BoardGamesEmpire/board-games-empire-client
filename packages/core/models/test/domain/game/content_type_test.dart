import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

Game _makeGame({required ContentType contentType}) {
  final now = DateTime.parse('2024-01-15T10:30:00Z');
  return Game(
    id: 'game_1',
    title: 'Test Game',
    contentType: contentType,
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  group('ContentType', () {
    test('every Dart value round-trips through Game.contentType', () {
      for (final value in ContentType.values) {
        final game = _makeGame(contentType: value);
        final round = Game.fromJson(game.toJson());
        expect(
          round.contentType,
          equals(value),
          reason: 'ContentType.${value.name} should survive a JSON round-trip',
        );
      }
    });

    test('wire format is PascalCase to match server', () {
      const expectations = <ContentType, String>{
        ContentType.accessory: 'Accessory',
        ContentType.baseGame: 'BaseGame',
        ContentType.bundle: 'Bundle',
        ContentType.dlc: 'DLC',
        ContentType.expandedEdition: 'ExpandedEdition',
        ContentType.expansion: 'Expansion',
        ContentType.mod: 'Mod',
        ContentType.port: 'Port',
        ContentType.remake: 'Remake',
        ContentType.remaster: 'Remaster',
        ContentType.standaloneExpansion: 'StandaloneExpansion',
        ContentType.unknown: 'Unknown',
      };

      for (final entry in expectations.entries) {
        final json = _makeGame(contentType: entry.key).toJson();
        expect(
          json['contentType'],
          equals(entry.value),
          reason:
              'ContentType.${entry.key.name} should serialize as "${entry.value}"',
        );
      }
    });

    test('every Prisma ContentType value has a Dart binding', () {
      // Mirrors prisma/models/game/content-type.prisma at the time of writing.
      const serverValues = <String>[
        'Accessory',
        'BaseGame',
        'Bundle',
        'DLC',
        'ExpandedEdition',
        'Expansion',
        'Mod',
        'Port',
        'Remake',
        'Remaster',
        'StandaloneExpansion',
        'Unknown',
      ];

      for (final wireValue in serverValues) {
        final json = _makeGame(contentType: ContentType.unknown).toJson();
        json['contentType'] = wireValue;
        expect(
          () => Game.fromJson(json),
          returnsNormally,
          reason: 'server value "$wireValue" must deserialize',
        );
      }
    });

    test('static fromJson/toJson helpers agree with @JsonValue mappings', () {
      // Storage layer calls the static helpers directly; they must
      // produce the same wire strings as @JsonValue. Guards against
      // drift between the two paths during the Pass 1->3 transition.
      for (final value in ContentType.values) {
        final viaJsonValue =
            _makeGame(contentType: value).toJson()['contentType'] as String;
        expect(value.toJson(), equals(viaJsonValue));
        expect(ContentType.fromJson(viaJsonValue), equals(value));
      }
    });
  });
}
