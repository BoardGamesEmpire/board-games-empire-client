import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

/// The summary every collection response embeds, as the data source maps it.
PlatformGameSummary _summary({
  String title = 'Brass: Birmingham',
  String? subtitle,
  String? gameThumbnail = 'g_thumb.png',
  String? platformThumbnail,
  List<ExpansionLink>? baseGames,
  ContentType? contentType,
  GameSummaryFacts? gameFacts,
  PlatformGameSummaryFacts? platformFacts,
}) => PlatformGameSummary(
  id: 'pg-1',
  platformId: 'plat-1',
  platformName: 'Tabletop',
  thumbnail: platformThumbnail,
  facts: platformFacts,
  game: GameSummary(
    id: 'g-1',
    title: title,
    subtitle: subtitle,
    image: 'g.png',
    thumbnail: gameThumbnail,
    baseGames: baseGames,
    contentType: contentType,
    facts: gameFacts,
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

    test('a summary with links replaces the cached links (#711)', () async {
      final seeded = DateTime.utc(2020);
      await repo().cacheGame(
        Game(
          id: 'g-1',
          title: 'Brass: Birmingham',
          baseGames: const [ExpansionLink(gameId: 'b1', isStandalone: false)],
          createdAt: seeded,
          updatedAt: seeded,
        ),
      );

      await repo().cachePlatformGameSummaries([
        _summary(
          baseGames: const [ExpansionLink(gameId: 'b2', isStandalone: true)],
        ),
      ]);

      expect((await repo().getGame('g-1'))?.baseGames, const [
        ExpansionLink(gameId: 'b2', isStandalone: true),
      ]);
    });

    test('a summary with no links clears the cached links (#711)', () async {
      final seeded = DateTime.utc(2020);
      await repo().cacheGame(
        Game(
          id: 'g-1',
          title: 'Brass: Birmingham',
          baseGames: const [ExpansionLink(gameId: 'b1', isStandalone: false)],
          createdAt: seeded,
          updatedAt: seeded,
        ),
      );

      await repo().cachePlatformGameSummaries([_summary(baseGames: const [])]);

      expect((await repo().getGame('g-1'))?.baseGames, isEmpty);
    });

    test("a summary's content type is written (#711)", () async {
      await repo().cachePlatformGameSummaries([
        _summary(contentType: ContentType.expansion),
      ]);

      final row = await db.select(db.gamesTable).getSingle();
      expect(row.contentType, 'Expansion');
    });

    test('a summary without links keeps the cached links and content '
        'type (#711)', () async {
      final seeded = DateTime.utc(2020);
      await repo().cacheGame(
        Game(
          id: 'g-1',
          title: 'Brass: Birmingham',
          contentType: ContentType.expansion,
          baseGames: const [ExpansionLink(gameId: 'b1', isStandalone: false)],
          createdAt: seeded,
          updatedAt: seeded,
        ),
      );

      await repo().cachePlatformGameSummaries([_summary()]);

      final row = await db.select(db.gamesTable).getSingle();
      expect(row.contentType, 'Expansion');
      expect((await repo().getGame('g-1'))?.baseGames, const [
        ExpansionLink(gameId: 'b1', isStandalone: false),
      ]);
    });

    group('the filter facts (#715)', () {
      /// A full record whose facts a summary can then keep or overwrite.
      Future<void> seedFullRecord() async {
        final seeded = DateTime.utc(2020);
        await repo().cacheGame(
          Game(
            id: 'g-1',
            title: 'Brass: Birmingham',
            publishYear: 2019,
            minPlayers: 2,
            maxPlayers: 4,
            minPlayTime: 60,
            maxPlayTime: 120,
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
            platformType: PlatformType.tabletop,
            minPlayers: 1,
            maxPlayers: 3,
            minPlayTime: 30,
            maxPlayTime: 90,
            createdAt: seeded,
            updatedAt: seeded,
          ),
        );
      }

      test('a summary with facts writes the game and platform game '
          'columns', () async {
        await repo().cachePlatformGameSummaries([
          _summary(
            gameFacts: const GameSummaryFacts(
              publishYear: 2018,
              minPlayers: 2,
              maxPlayers: 4,
              minPlayTime: 60,
              maxPlayTime: 120,
            ),
            platformFacts: const PlatformGameSummaryFacts(
              platformType: PlatformType.tabletop,
              minPlayers: 1,
              maxPlayers: 3,
              minPlayTime: 30,
              maxPlayTime: 90,
            ),
          ),
        ]);

        final game = await db.select(db.gamesTable).getSingle();
        expect(game.publishYear, 2018);
        expect(game.minPlayers, 2);
        expect(game.maxPlayers, 4);
        expect(game.minPlayTime, 60);
        expect(game.maxPlayTime, 120);
        final platformGame = await db.select(db.platformGamesTable).getSingle();
        expect(platformGame.platformType, 'Tabletop');
        expect(platformGame.minPlayers, 1);
        expect(platformGame.maxPlayers, 3);
        expect(platformGame.minPlayTime, 30);
        expect(platformGame.maxPlayTime, 90);
      });

      test('a summary with facts replaces the facts of a full '
          'record', () async {
        await seedFullRecord();

        await repo().cachePlatformGameSummaries([
          _summary(
            gameFacts: const GameSummaryFacts(
              publishYear: 2020,
              minPlayers: 3,
              maxPlayers: 5,
              minPlayTime: 45,
              maxPlayTime: 75,
            ),
            platformFacts: const PlatformGameSummaryFacts(
              platformType: PlatformType.console,
              minPlayers: 2,
              maxPlayers: 6,
              minPlayTime: 20,
              maxPlayTime: 40,
            ),
          ),
        ]);

        final game = await db.select(db.gamesTable).getSingle();
        expect(game.publishYear, 2020);
        expect(game.minPlayers, 3);
        expect(game.maxPlayers, 5);
        expect(game.minPlayTime, 45);
        expect(game.maxPlayTime, 75);
        final platformGame = await db.select(db.platformGamesTable).getSingle();
        expect(platformGame.platformType, PlatformType.console.toWire());
        expect(platformGame.minPlayers, 2);
        expect(platformGame.maxPlayers, 6);
        expect(platformGame.minPlayTime, 20);
        expect(platformGame.maxPlayTime, 40);
      });

      test('a summary with facts whose fields are null writes nulls over '
          'a full record', () async {
        await seedFullRecord();

        await repo().cachePlatformGameSummaries([
          _summary(
            gameFacts: const GameSummaryFacts(),
            platformFacts: const PlatformGameSummaryFacts(),
          ),
        ]);

        final game = await db.select(db.gamesTable).getSingle();
        expect(game.publishYear, isNull);
        expect(game.minPlayers, isNull);
        expect(game.maxPlayers, isNull);
        expect(game.minPlayTime, isNull);
        expect(game.maxPlayTime, isNull);
        final platformGame = await db.select(db.platformGamesTable).getSingle();
        expect(platformGame.platformType, isNull);
        expect(platformGame.minPlayers, isNull);
        expect(platformGame.maxPlayers, isNull);
        expect(platformGame.minPlayTime, isNull);
        expect(platformGame.maxPlayTime, isNull);
      });

      test('partly filled facts write each field as it is, nulls '
          'included', () async {
        await seedFullRecord();

        await repo().cachePlatformGameSummaries([
          _summary(
            gameFacts: const GameSummaryFacts(publishYear: 2021),
            platformFacts: const PlatformGameSummaryFacts(minPlayers: 4),
          ),
        ]);

        final game = await db.select(db.gamesTable).getSingle();
        expect(game.publishYear, 2021);
        expect(game.minPlayers, isNull);
        expect(game.maxPlayTime, isNull);
        final platformGame = await db.select(db.platformGamesTable).getSingle();
        expect(platformGame.platformType, isNull);
        expect(platformGame.minPlayers, 4);
        expect(platformGame.maxPlayers, isNull);
      });

      test('an unknown platform type is stored as null', () async {
        await seedFullRecord();

        await repo().cachePlatformGameSummaries([
          _summary(
            platformFacts: const PlatformGameSummaryFacts(
              platformType: PlatformType.unknown,
            ),
          ),
        ]);

        final platformGame = await db.select(db.platformGamesTable).getSingle();
        expect(platformGame.platformType, isNull);
      });

      test('a summary without facts keeps the facts of a full '
          'record', () async {
        await seedFullRecord();

        await repo().cachePlatformGameSummaries([_summary()]);

        final game = await db.select(db.gamesTable).getSingle();
        expect(game.publishYear, 2019);
        expect(game.minPlayers, 2);
        expect(game.maxPlayers, 4);
        expect(game.minPlayTime, 60);
        expect(game.maxPlayTime, 120);
        final platformGame = await db.select(db.platformGamesTable).getSingle();
        expect(platformGame.platformType, 'Tabletop');
        expect(platformGame.minPlayers, 1);
        expect(platformGame.maxPlayers, 3);
        expect(platformGame.minPlayTime, 30);
        expect(platformGame.maxPlayTime, 90);
      });

      test('a summary without facts leaves the new row facts null', () async {
        await repo().cachePlatformGameSummaries([_summary()]);

        final game = await db.select(db.gamesTable).getSingle();
        expect(game.publishYear, isNull);
        expect(game.minPlayers, isNull);
        final platformGame = await db.select(db.platformGamesTable).getSingle();
        expect(platformGame.platformType, isNull);
        expect(platformGame.minPlayers, isNull);
      });

      test('no summary write sets or clears fullRecordCachedAt', () async {
        // A summary-only row stays not cached, with or without facts.
        await repo().cachePlatformGameSummaries([
          _summary(
            gameFacts: const GameSummaryFacts(publishYear: 2018),
            platformFacts: const PlatformGameSummaryFacts(minPlayers: 1),
          ),
        ]);
        expect(
          (await db.select(db.gamesTable).getSingle()).fullRecordCachedAt,
          isNull,
        );
        expect(
          (await db.select(db.platformGamesTable).getSingle())
              .fullRecordCachedAt,
          isNull,
        );

        // A full record's mark survives a summary with and without facts.
        await seedFullRecord();
        final gameMark =
            (await db.select(db.gamesTable).getSingle()).fullRecordCachedAt;
        final platformMark =
            (await db.select(db.platformGamesTable).getSingle())
                .fullRecordCachedAt;
        expect(gameMark, isNotNull);
        expect(platformMark, isNotNull);

        await repo().cachePlatformGameSummaries([
          _summary(
            gameFacts: const GameSummaryFacts(),
            platformFacts: const PlatformGameSummaryFacts(),
          ),
        ]);
        await repo().cachePlatformGameSummaries([_summary()]);

        expect(
          (await db.select(db.gamesTable).getSingle()).fullRecordCachedAt,
          gameMark,
        );
        expect(
          (await db.select(db.platformGamesTable).getSingle())
              .fullRecordCachedAt,
          platformMark,
        );
      });
    });
  });
}
