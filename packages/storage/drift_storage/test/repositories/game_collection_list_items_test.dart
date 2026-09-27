import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_collection_repository_impl.dart';
import 'package:drift_storage/src/repositories/game_repository_impl.dart';

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
  String? gameThumbnail,
}) => PlatformGameSummary(
  id: id,
  platformId: 'plat-1',
  platformName: platformName,
  thumbnail: platformThumbnail,
  game: GameSummary(
    id: gameId,
    title: title,
    subtitle: subtitle,
    thumbnail: gameThumbnail,
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
    games = GameRepositoryImpl(db);
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
    await games.cachePlatformGameSummaries([summary]);
    await collection.mergeFromServer([entry]);
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

    test('leaves out another user\'s entry', () async {
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
}
