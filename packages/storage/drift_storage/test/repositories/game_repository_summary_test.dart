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
  final stamp = DateTime.utc(2026, 9, 26, 12);

  setUp(() => db = inMemoryServerDatabase());
  tearDown(() => db.close());

  GameRepositoryImpl repo({DateTime Function()? now}) =>
      GameRepositoryImpl(db, now: now ?? () => stamp);

  group('cachePlatformGameSummaries (#259)', () {
    test(
      'into an empty cache, creates the game and its platform game',
      () async {
        await repo().cachePlatformGameSummaries([_summary()]);

        final game = await repo().getGame('g-1');
        expect(game?.title, 'Brass: Birmingham');
        expect(game?.image, 'g.png');
        expect(game?.thumbnail, 'g_thumb.png');

        final platformGame = await repo().getPlatformGame('pg-1');
        expect(platformGame?.gameId, 'g-1');
        expect(platformGame?.platformId, 'plat-1');
        expect(platformGame?.platformName, 'Tabletop');
        expect(platformGame?.thumbnail, isNull);
      },
    );

    test('stamps the timestamps of a row it inserts from the local clock, '
        'since the summary carries none', () async {
      await repo().cachePlatformGameSummaries([_summary()]);

      final game = await repo().getGame('g-1');
      final platformGame = await repo().getPlatformGame('pg-1');
      expect(game?.createdAt, stamp);
      expect(game?.updatedAt, stamp);
      expect(platformGame?.createdAt, stamp);
      expect(platformGame?.updatedAt, stamp);
    });

    test('over a full record, changes only the columns the summary '
        'carries', () async {
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

    test(
      'a later summary replaces the summary fields, nulls included',
      () async {
        await repo().cachePlatformGameSummaries([_summary(subtitle: 'Deluxe')]);
        await repo().cachePlatformGameSummaries([
          _summary(title: 'Brass', gameThumbnail: null),
        ]);

        final game = await repo().getGame('g-1');
        expect(game?.title, 'Brass');
        expect(game?.subtitle, isNull);
        expect(game?.thumbnail, isNull);
      },
    );
  });
}
