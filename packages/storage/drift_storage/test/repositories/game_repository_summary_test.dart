import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_repository_impl.dart';

/// The summary every collection response embeds, as the data source maps it.
PlatformGameSummary _summary({
  String title = 'Brass: Birmingham',
  String? subtitle,
  String? gameThumbnail = 'g_thumb.png',
  String? platformThumbnail,
}) => PlatformGameSummary(
  id: 'pg-1',
  platformId: 'plat-1',
  platformName: 'Tabletop',
  thumbnail: platformThumbnail,
  game: GameSummary(
    id: 'g-1',
    title: title,
    subtitle: subtitle,
    image: 'g.png',
    thumbnail: gameThumbnail,
  ),
);

void main() {
  late ServerDatabase db;

  setUp(() => db = inMemoryServerDatabase());
  tearDown(() => db.close());

  GameRepositoryImpl repo() => GameRepositoryImpl(db, userId: 'user-abc');

  group('cachePlatformGameSummaries (#259)', () {
    test('a row only a summary wrote reads back as not cached, through '
        'every read (#406)', () async {
      await repo().cachePlatformGameSummaries([_summary()]);

      expect(await repo().getGame('g-1'), isNull);
      expect(await repo().getGames(['g-1']), isEmpty);
      expect(await repo().searchGames('brass'), isEmpty);
      expect(await repo().watchGame('g-1').first, isNull);
      expect(await repo().watchGames().first, isEmpty);
      expect(await repo().getPlatformGame('pg-1'), isNull);
      expect(await repo().getPlatformGamesForGame('g-1'), isEmpty);
    });

    test('a full write over a summary-only row makes it readable '
        '(#406)', () async {
      final seeded = DateTime.utc(2020);
      await repo().cachePlatformGameSummaries([_summary()]);

      await repo().cacheGame(
        Game(
          id: 'g-1',
          title: 'Brass: Birmingham',
          minPlayers: 2,
          createdAt: seeded,
          updatedAt: seeded,
        ),
      );
      await repo().cachePlatformGame(
        PlatformGame(
          id: 'pg-1',
          gameId: 'g-1',
          platformId: 'plat-1',
          platformName: 'Tabletop',
          supportsSolo: true,
          createdAt: seeded,
          updatedAt: seeded,
        ),
      );

      final game = await repo().getGame('g-1');
      expect(game?.minPlayers, 2);
      expect(game?.createdAt, seeded);
      final platformGame = await repo().getPlatformGame('pg-1');
      expect(platformGame?.supportsSolo, isTrue);
      expect(platformGame?.createdAt, seeded);
    });

    test('over a full record, changes only the columns the summary '
        'carries, and the record stays readable (#406)', () async {
      final seeded = DateTime.utc(2020);
      await repo().cacheGame(
        Game(
          id: 'g-1',
          title: 'Old title',
          description: 'An economic game',
          minPlayers: 2,
          maxPlayers: 4,
          categories: const ['Economic'],
          createdAt: seeded,
          updatedAt: seeded,
        ),
      );
      await repo().cachePlatformGame(
        PlatformGame(
          id: 'pg-1',
          gameId: 'g-1',
          platformId: 'plat-1',
          platformName: 'Old platform',
          minPlayers: 1,
          supportsSolo: true,
          createdAt: seeded,
          updatedAt: seeded,
        ),
      );

      await repo().cachePlatformGameSummaries([
        _summary(platformThumbnail: 'pg_thumb.png'),
      ]);

      final game = await repo().getGame('g-1');
      expect(game?.title, 'Brass: Birmingham');
      expect(game?.thumbnail, 'g_thumb.png');
      expect(game?.description, 'An economic game');
      expect(game?.minPlayers, 2);
      expect(game?.maxPlayers, 4);
      expect(game?.categories, ['Economic']);
      expect(game?.createdAt, seeded);
      expect(game?.updatedAt, seeded);

      final platformGame = await repo().getPlatformGame('pg-1');
      expect(platformGame?.platformName, 'Tabletop');
      expect(platformGame?.thumbnail, 'pg_thumb.png');
      expect(platformGame?.minPlayers, 1);
      expect(platformGame?.supportsSolo, isTrue);
      expect(platformGame?.createdAt, seeded);
      expect(platformGame?.updatedAt, seeded);
    });

    test('a later summary replaces the summary fields, nulls '
        'included', () async {
      final seeded = DateTime.utc(2020);
      await repo().cacheGame(
        Game(
          id: 'g-1',
          title: 'Brass: Birmingham',
          subtitle: 'Deluxe',
          thumbnail: 'g_thumb.png',
          createdAt: seeded,
          updatedAt: seeded,
        ),
      );

      await repo().cachePlatformGameSummaries([
        _summary(title: 'Brass', gameThumbnail: null),
      ]);

      final game = await repo().getGame('g-1');
      expect(game?.title, 'Brass');
      expect(game?.subtitle, isNull);
      expect(game?.thumbnail, isNull);
    });
  });
}
