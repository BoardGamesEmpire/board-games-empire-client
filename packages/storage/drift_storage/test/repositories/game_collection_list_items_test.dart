import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_collection_repository_impl.dart';
import 'package:drift_storage/src/repositories/game_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import '../support/system_clock.dart';

class _MockSyncQueue extends Mock implements SyncQueueRepository {}

const _kUserId = 'user-abc';

PlatformGameSummary _summary({
  required String id,
  required String gameId,
  required String title,
  String? subtitle,
  String platformName = 'Tabletop',
  String? platformThumbnail,
  String? platformImage,
  String? gameThumbnail,
  String? gameImage,
  List<ExpansionLink>? baseGames,
  ContentType? contentType,
  GameSummaryFacts? gameFacts,
  PlatformGameSummaryFacts? platformFacts,
}) => PlatformGameSummary(
  id: id,
  platformId: 'plat-1',
  platformName: platformName,
  thumbnail: platformThumbnail,
  image: platformImage,
  facts: platformFacts,
  game: GameSummary(
    id: gameId,
    title: title,
    subtitle: subtitle,
    thumbnail: gameThumbnail,
    image: gameImage,
    baseGames: baseGames,
    contentType: contentType,
    facts: gameFacts,
  ),
);

GameCollection _entry({
  required String id,
  required String platformGameId,
  String userId = _kUserId,
}) => GameCollection(
  id: id,
  userId: userId,
  platformGameId: platformGameId,
  medium: GameMedium.physical,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// The list reads the entry and its display fields in one stream (#259), so
/// the screen neither joins nor knows the thumbnail fallback.
void main() {
  setUpAll(() {
    registerFallbackValue(
      const RemoveFromCollectionOperation(collectionId: ''),
    );
  });

  late ServerDatabase db;
  late GameRepositoryImpl games;
  late GameCollectionRepositoryImpl collection;

  setUp(() {
    db = inMemoryServerDatabase();
    games = GameRepositoryImpl(db, userId: _kUserId);
    final queue = _MockSyncQueue();
    when(() => queue.enqueue(any())).thenAnswer(
      (_) async => SyncQueueEntry(
        id: 'sq-1',
        payload: '{}',
        createdAt: DateTime.now().toUtc(),
      ),
    );
    collection = GameCollectionRepositoryImpl(
      db: db,
      syncQueue: queue,
      currentUserId: _kUserId,
      clock: const SystemClockService(),
    );
  });

  tearDown(() async => db.close());

  /// What a hydrate does per row: the summary, then the entry.
  Future<void> hydrate(
    PlatformGameSummary summary,
    GameCollection entry,
  ) async {
    final mark = await collection.removalMark();
    await games.cachePlatformGameSummaries([summary]);
    await collection.mergeFromServer([entry], removalsSince: mark);
  }

  group('watchCollectionListItems (#259)', () {
    test('emits each entry with its title, subtitle and platform', () async {
      await hydrate(
        _summary(
          id: 'pg-1',
          gameId: 'g-1',
          title: 'Brass',
          subtitle: 'Birmingham',
        ),
        _entry(id: 'gc-1', platformGameId: 'pg-1'),
      );

      final item = (await collection.watchCollectionListItems().first).single;

      expect(item.entry.id, 'gc-1');
      expect(item.title, 'Brass');
      expect(item.subtitle, 'Birmingham');
      expect(item.platformName, 'Tabletop');
    });

    test('list item carries the game id', () async {
      await hydrate(
        _summary(id: 'pg-1', gameId: 'g-1', title: 'Brass'),
        _entry(id: 'gc-1', platformGameId: 'pg-1'),
      );

      final item = (await collection.watchCollectionListItems().first).single;

      expect(item.gameId, 'g-1');
    });

    test(
      "a list item carries its game's base games and content type",
      () async {
        await hydrate(
          _summary(
            id: 'pg-1',
            gameId: 'g-1',
            title: 'Brass',
            baseGames: const [ExpansionLink(gameId: 'b1', isStandalone: false)],
            contentType: ContentType.dlc,
          ),
          _entry(id: 'gc-1', platformGameId: 'pg-1'),
        );

        final item = (await collection.watchCollectionListItems().first).single;

        expect(item.baseGames, const [
          ExpansionLink(gameId: 'b1', isStandalone: false),
        ]);
        expect(item.contentType, ContentType.dlc);
      },
    );

    group('the filter facts (#715)', () {
      test('a row whose platform game sets one of its players resolves the '
          'pair from the platform game', () async {
        await hydrate(
          _summary(
            id: 'pg-1',
            gameId: 'g-1',
            title: 'Brass',
            gameFacts: const GameSummaryFacts(minPlayers: 1, maxPlayers: 5),
            platformFacts: const PlatformGameSummaryFacts(minPlayers: 2),
          ),
          _entry(id: 'gc-1', platformGameId: 'pg-1'),
        );

        final item = (await collection.watchCollectionListItems().first).single;

        expect(item.minPlayers, 2);
        expect(item.maxPlayers, isNull);
      });

      test('a platform game with no players resolves to the game '
          'pair', () async {
        await hydrate(
          _summary(
            id: 'pg-1',
            gameId: 'g-1',
            title: 'Brass',
            gameFacts: const GameSummaryFacts(minPlayers: 1, maxPlayers: 5),
            platformFacts: const PlatformGameSummaryFacts(),
          ),
          _entry(id: 'gc-1', platformGameId: 'pg-1'),
        );

        final item = (await collection.watchCollectionListItems().first).single;

        expect(item.minPlayers, 1);
        expect(item.maxPlayers, 5);
      });

      test('play time resolves as a pair, from the platform game when '
          'either of its two is set', () async {
        await hydrate(
          _summary(
            id: 'pg-1',
            gameId: 'g-1',
            title: 'Brass',
            gameFacts: const GameSummaryFacts(minPlayTime: 60, maxPlayTime: 90),
            platformFacts: const PlatformGameSummaryFacts(maxPlayTime: 45),
          ),
          _entry(id: 'gc-1', platformGameId: 'pg-1'),
        );
        await hydrate(
          _summary(
            id: 'pg-2',
            gameId: 'g-2',
            title: 'Catan',
            gameFacts: const GameSummaryFacts(minPlayTime: 60, maxPlayTime: 90),
            platformFacts: const PlatformGameSummaryFacts(),
          ),
          _entry(id: 'gc-2', platformGameId: 'pg-2'),
        );

        final items = await collection.watchCollectionListItems().first;
        final brass = items.firstWhere((i) => i.entry.id == 'gc-1');
        final catan = items.firstWhere((i) => i.entry.id == 'gc-2');

        expect(brass.minPlayTime, isNull);
        expect(brass.maxPlayTime, 45);
        expect(catan.minPlayTime, 60);
        expect(catan.maxPlayTime, 90);
      });

      test("carries the game's publish year and the platform type", () async {
        await hydrate(
          _summary(
            id: 'pg-1',
            gameId: 'g-1',
            title: 'Brass',
            gameFacts: const GameSummaryFacts(publishYear: 2018),
            platformFacts: const PlatformGameSummaryFacts(
              platformType: PlatformType.console,
            ),
          ),
          _entry(id: 'gc-1', platformGameId: 'pg-1'),
        );

        final item = (await collection.watchCollectionListItems().first).single;

        expect(item.publishYear, 2018);
        expect(item.platformType, PlatformType.console);
      });

      test('a row written by a summary without facts has no value for '
          'any of the six', () async {
        await hydrate(
          _summary(id: 'pg-1', gameId: 'g-1', title: 'Brass'),
          _entry(id: 'gc-1', platformGameId: 'pg-1'),
        );

        final item = (await collection.watchCollectionListItems().first).single;

        expect(item.platformType, isNull);
        expect(item.publishYear, isNull);
        expect(item.minPlayers, isNull);
        expect(item.maxPlayers, isNull);
        expect(item.minPlayTime, isNull);
        expect(item.maxPlayTime, isNull);
      });

      test('an unknown platform type reads back as no platform '
          'type', () async {
        await hydrate(
          _summary(
            id: 'pg-1',
            gameId: 'g-1',
            title: 'Brass',
            platformFacts: const PlatformGameSummaryFacts(
              platformType: PlatformType.unknown,
            ),
          ),
          _entry(id: 'gc-1', platformGameId: 'pg-1'),
        );

        final item = (await collection.watchCollectionListItems().first).single;

        expect(item.platformType, isNull);
      });

      test('watchCollectionListItem carries them too', () async {
        await hydrate(
          _summary(
            id: 'pg-1',
            gameId: 'g-1',
            title: 'Brass',
            gameFacts: const GameSummaryFacts(
              publishYear: 2018,
              minPlayers: 2,
              maxPlayers: 4,
            ),
            platformFacts: const PlatformGameSummaryFacts(
              platformType: PlatformType.tabletop,
            ),
          ),
          _entry(id: 'gc-1', platformGameId: 'pg-1'),
        );

        final item = await collection.watchCollectionListItem('gc-1').first;

        expect(item?.publishYear, 2018);
        expect(item?.minPlayers, 2);
        expect(item?.maxPlayers, 4);
        expect(item?.platformType, PlatformType.tabletop);
      });
    });

    test('two platform games of one game carry the same game id', () async {
      await hydrate(
        _summary(id: 'pg-1', gameId: 'g-1', title: 'Brass'),
        _entry(id: 'gc-1', platformGameId: 'pg-1'),
      );
      await hydrate(
        _summary(
          id: 'pg-2',
          gameId: 'g-1',
          title: 'Brass',
          platformName: 'Steam',
        ),
        _entry(id: 'gc-2', platformGameId: 'pg-2'),
      );

      final items = await collection.watchCollectionListItems().first;

      expect(items.map((i) => i.gameId), ['g-1', 'g-1']);
    });

    test('prefers the platform game thumbnail over the game one', () async {
      await hydrate(
        _summary(
          id: 'pg-1',
          gameId: 'g-1',
          title: 'Brass',
          platformThumbnail: 'pg_thumb.png',
          gameThumbnail: 'g_thumb.png',
        ),
        _entry(id: 'gc-1', platformGameId: 'pg-1'),
      );

      final item = (await collection.watchCollectionListItems().first).single;
      expect(item.thumbnail, 'pg_thumb.png');
    });

    test('falls back to the game thumbnail when the platform game has '
        'none', () async {
      await hydrate(
        _summary(
          id: 'pg-1',
          gameId: 'g-1',
          title: 'Brass',
          gameThumbnail: 'g_thumb.png',
        ),
        _entry(id: 'gc-1', platformGameId: 'pg-1'),
      );

      final item = (await collection.watchCollectionListItems().first).single;
      expect(item.thumbnail, 'g_thumb.png');
    });

    // #709: a platform game's own picture wins even when it is only a full
    // image, and the game's image stands in when nothing has a thumbnail.
    test("prefers the platform game's image over the game's thumbnail when "
        'the platform game has no thumbnail', () async {
      await hydrate(
        _summary(
          id: 'pg-1',
          gameId: 'g-1',
          title: 'Brass',
          platformImage: 'pg_image.png',
          gameThumbnail: 'g_thumb.png',
          gameImage: 'g_image.png',
        ),
        _entry(id: 'gc-1', platformGameId: 'pg-1'),
      );

      final item = (await collection.watchCollectionListItems().first).single;
      expect(item.thumbnail, 'pg_image.png');
    });

    test("prefers the platform game's thumbnail over its image", () async {
      await hydrate(
        _summary(
          id: 'pg-1',
          gameId: 'g-1',
          title: 'Brass',
          platformThumbnail: 'pg_thumb.png',
          platformImage: 'pg_image.png',
        ),
        _entry(id: 'gc-1', platformGameId: 'pg-1'),
      );

      final item = (await collection.watchCollectionListItems().first).single;
      expect(item.thumbnail, 'pg_thumb.png');
    });

    test(
      "falls back to the game's image when nothing has a thumbnail",
      () async {
        await hydrate(
          _summary(
            id: 'pg-1',
            gameId: 'g-1',
            title: 'Brass',
            gameImage: 'g_image.png',
          ),
          _entry(id: 'gc-1', platformGameId: 'pg-1'),
        );

        final item = (await collection.watchCollectionListItems().first).single;
        expect(item.thumbnail, 'g_image.png');
      },
    );

    test('re-emits when a later summary changes the title', () async {
      await hydrate(
        _summary(id: 'pg-1', gameId: 'g-1', title: 'Brass'),
        _entry(id: 'gc-1', platformGameId: 'pg-1'),
      );

      final titles = collection.watchCollectionListItems().map(
        (items) => items.single.title,
      );
      final expectation = expectLater(
        titles,
        emitsInOrder(['Brass', 'Brass: Birmingham']),
      );

      await Future<void>.delayed(Duration.zero);
      await games.cachePlatformGameSummaries([
        _summary(id: 'pg-1', gameId: 'g-1', title: 'Brass: Birmingham'),
      ]);

      await expectation;
    });

    test('orders the list by title, ignoring case', () async {
      await hydrate(
        _summary(id: 'pg-1', gameId: 'g-1', title: 'wingspan'),
        _entry(id: 'gc-1', platformGameId: 'pg-1'),
      );
      await hydrate(
        _summary(id: 'pg-2', gameId: 'g-2', title: 'Azul'),
        _entry(id: 'gc-2', platformGameId: 'pg-2'),
      );
      await hydrate(
        _summary(id: 'pg-3', gameId: 'g-3', title: 'Brass'),
        _entry(id: 'gc-3', platformGameId: 'pg-3'),
      );

      final items = await collection.watchCollectionListItems().first;
      expect(items.map((i) => i.title), ['Azul', 'Brass', 'wingspan']);
    });

    test('leaves out a removed entry', () async {
      await hydrate(
        _summary(id: 'pg-1', gameId: 'g-1', title: 'Brass'),
        _entry(id: 'gc-1', platformGameId: 'pg-1'),
      );

      await collection.removeFromCollection('gc-1');

      expect(await collection.watchCollectionListItems().first, isEmpty);
    });

    test("leaves out another user's entry", () async {
      await games.cachePlatformGameSummaries([
        _summary(id: 'pg-1', gameId: 'g-1', title: 'Brass'),
      ]);
      await db
          .into(db.gameCollectionsTable)
          .insert(
            GameCollectionsTableCompanion.insert(
              id: 'gc-foreign',
              userId: 'someone-else',
              platformGameId: 'pg-1',
              medium: 'Physical',
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
            ),
          );

      expect(await collection.watchCollectionListItems().first, isEmpty);
    });

    test('closes when the repository is disposed', () async {
      final done = expectLater(
        collection.watchCollectionListItems(),
        emitsThrough(emitsDone),
      );

      await Future<void>.delayed(Duration.zero);
      await collection.onDispose();

      await done;
    });
  });

  group('watchCollectionListItem (#46)', () {
    test('emits the entry with its title, platform and thumbnail', () async {
      await hydrate(
        _summary(
          id: 'pg-1',
          gameId: 'g-1',
          title: 'Brass',
          gameThumbnail: 'g_thumb.png',
        ),
        _entry(id: 'gc-1', platformGameId: 'pg-1'),
      );

      final item = await collection.watchCollectionListItem('gc-1').first;

      expect(item, isNotNull);
      expect(item!.entry.id, 'gc-1');
      expect(item.title, 'Brass');
      expect(item.platformName, 'Tabletop');
      expect(item.thumbnail, 'g_thumb.png');
    });

    test('emits null once the entry is removed', () async {
      await hydrate(
        _summary(id: 'pg-1', gameId: 'g-1', title: 'Brass'),
        _entry(id: 'gc-1', platformGameId: 'pg-1'),
      );

      final expectation = expectLater(
        collection.watchCollectionListItem('gc-1'),
        emitsInOrder([isA<GameCollectionListItem>(), isNull]),
      );

      await Future<void>.delayed(Duration.zero);
      await collection.removeFromCollection('gc-1');

      await expectation;
    });

    test('emits null for an id that is not there', () async {
      expect(await collection.watchCollectionListItem('nope').first, isNull);
    });

    test("emits null for another user's entry id", () async {
      await games.cachePlatformGameSummaries([
        _summary(id: 'pg-1', gameId: 'g-1', title: 'Brass'),
      ]);
      await db
          .into(db.gameCollectionsTable)
          .insert(
            GameCollectionsTableCompanion.insert(
              id: 'gc-foreign',
              userId: 'someone-else',
              platformGameId: 'pg-1',
              medium: 'Physical',
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
            ),
          );

      expect(
        await collection.watchCollectionListItem('gc-foreign').first,
        isNull,
      );
    });

    test("re-emits when the game's title changes", () async {
      await hydrate(
        _summary(id: 'pg-1', gameId: 'g-1', title: 'Brass'),
        _entry(id: 'gc-1', platformGameId: 'pg-1'),
      );

      final titles = collection
          .watchCollectionListItem('gc-1')
          .map((item) => item!.title);
      final expectation = expectLater(
        titles,
        emitsInOrder(['Brass', 'Brass: Birmingham']),
      );

      await Future<void>.delayed(Duration.zero);
      await games.cachePlatformGameSummaries([
        _summary(id: 'pg-1', gameId: 'g-1', title: 'Brass: Birmingham'),
      ]);

      await expectation;
    });

    test('closes when the repository is disposed', () async {
      final done = expectLater(
        collection.watchCollectionListItem('gc-1'),
        emitsThrough(emitsDone),
      );

      await Future<void>.delayed(Duration.zero);
      await collection.onDispose();

      await done;
    });
  });
}
