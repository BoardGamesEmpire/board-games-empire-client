import 'package:test/test.dart';
import 'package:models/domain.dart';

DateTime get _now => DateTime.parse('2024-01-15T10:30:00Z');

Game _make({
  ContentType contentType = ContentType.baseGame,
  Reach reach = Reach.public,
  String? createdById,
  List<String> tags = const <String>[],
  int totalPlayCount = 0,
  int? minPlayers = 3,
  int? maxPlayers = 4,
}) => Game(
  id: 'game_1',
  title: 'Catan',
  subtitle: 'The Settlers of',
  contentType: contentType,
  reach: reach,
  createdById: createdById,
  tags: tags,
  totalPlayCount: totalPlayCount,
  minPlayers: minPlayers,
  maxPlayers: maxPlayers,
  createdAt: _now,
  updatedAt: _now,
);

void main() {
  group('Game', () {
    test('defaults for new aggregate fields are sensible', () {
      final game = _make();
      expect(game.totalPlayCount, equals(0));
      expect(game.reach, equals(Reach.public));
      expect(game.createdById, isNull);
      expect(game.tags, isEmpty);
      expect(game.ownedByCount, equals(0));
      expect(game.categories, isEmpty);
      expect(game.mechanics, isEmpty);
      expect(game.designers, isEmpty);
      expect(game.publishers, isEmpty);
      expect(game.isDeleted, isFalse);
    });

    test('serializes added fields with camelCase keys', () {
      final game = _make(
        reach: Reach.private,
        createdById: 'user_123',
        tags: const ['family', 'classic'],
        totalPlayCount: 42,
      );
      final json = game.toJson();

      expect(json['reach'], equals('Private'));
      expect(json['createdById'], equals('user_123'));
      expect(json['tags'], equals(<String>['family', 'classic']));
      expect(json['totalPlayCount'], equals(42));
    });

    test('round-trips a fully populated game', () {
      final game = Game(
        id: 'game_2',
        title: 'Brass',
        subtitle: 'Birmingham',
        description: 'Industrial revolution era',
        image: 'https://cdn/img.jpg',
        thumbnail: 'https://cdn/thumb.jpg',
        publishYear: 2018,
        minPlayers: 2,
        maxPlayers: 4,
        minPlayTime: 60,
        maxPlayTime: 120,
        minAge: 14,
        complexity: 3.89,
        contentType: ContentType.baseGame,
        totalPlayCount: 999,
        averageRating: 8.62,
        bayesRating: 8.4,
        ratingsCount: 50000,
        ownedByCount: 75000,
        categories: const ['economic', 'industry'],
        mechanics: const ['network building', 'hand management'],
        designers: const ['Martin Wallace'],
        publishers: const ['Roxley'],
        tags: const ['heavy', 'highly rated'],
        reach: Reach.public,
        createdById: null,
        createdAt: _now,
        updatedAt: _now,
      );

      final round = Game.fromJson(game.toJson());
      expect(round, equals(game));
    });

    test('Reach round-trips through Game.reach', () {
      for (final value in Reach.values.where((r) => r != Reach.unknown)) {
        final game = _make(reach: value);
        final round = Game.fromJson(game.toJson());
        expect(round.reach, equals(value));
      }
    });

    test('JSON omitting reach defaults to Public', () {
      final json = _make().toJson();
      json.remove('reach');
      final round = Game.fromJson(json);
      expect(round.reach, equals(Reach.public));
    });

    test('JSON with a reach this client does not know reads as unknown', () {
      final json = _make().toJson();
      json['reach'] = 'Guild';
      expect(Game.fromJson(json).reach, equals(Reach.unknown));
    });

    test('Game.fromJson with an unknown contentType wire value falls back to '
        'ContentType.unknown', () {
      final json = _make().toJson();

      // Sanity: the wire form for ContentType is the @JsonValue
      // PascalCase string ('BaseGame'), not the Dart enum name.
      expect(json['contentType'], equals('BaseGame'));

      // Replace with a value the client doesn't know about,
      // simulating a server-added ContentType variant.
      json['contentType'] = 'NewServerContentType';

      final game = Game.fromJson(json);
      expect(game.contentType, equals(ContentType.unknown));
    });

    group('playerCountDisplay', () {
      test('shows range', () {
        expect(_make().playerCountDisplay, equals('3–4'));
      });
      test('shows single number when min == max', () {
        expect(
          _make(minPlayers: 1, maxPlayers: 1).playerCountDisplay,
          equals('1'),
        );
      });
      test('shows "Up to N" when no minimum', () {
        expect(
          _make(minPlayers: null, maxPlayers: 6).playerCountDisplay,
          equals('Up to 6'),
        );
      });
      test('shows "N+" when no maximum', () {
        expect(
          _make(minPlayers: 2, maxPlayers: null).playerCountDisplay,
          equals('2+'),
        );
      });
      test('returns null when both null', () {
        expect(
          _make(minPlayers: null, maxPlayers: null).playerCountDisplay,
          isNull,
        );
      });
    });

    test('isDeleted reflects deletedAt', () {
      expect(_make().isDeleted, isFalse);
      expect(_make().copyWith(deletedAt: _now).isDeleted, isTrue);
    });
  });
}
