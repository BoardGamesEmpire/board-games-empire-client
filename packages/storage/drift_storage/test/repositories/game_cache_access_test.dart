import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_cache_access.dart';
import 'package:drift_storage/src/tables/game_access_table.dart';

import '../support/platform_game_fixture.dart';

const _kUserA = 'user-a';
const _kUserB = 'user-b';

void main() {
  late ServerDatabase db;
  late GameCacheAccess access;

  setUp(() {
    db = inMemoryServerDatabase();
    access = GameCacheAccess(db);
  });
  tearDown(() => db.close());

  Future<void> gameRecord(
    String userId,
    String gameId, [
    String source = cacheAccessSourceCatalog,
  ]) => db
      .into(db.gameAccessTable)
      .insert(
        GameAccessTableCompanion.insert(
          userId: userId,
          gameId: gameId,
          source: source,
        ),
      );

  Future<void> platformRecord(
    String userId,
    String platformGameId, [
    String source = cacheAccessSourceCatalog,
  ]) => db
      .into(db.platformGameAccessTable)
      .insert(
        PlatformGameAccessTableCompanion.insert(
          userId: userId,
          platformGameId: platformGameId,
          source: source,
        ),
      );

  Future<void> collectionRow(
    String userId,
    String platformGameId, {
    String id = 'c-1',
    String medium = 'physical',
    DateTime? deletedAt,
  }) {
    final now = DateTime.now().toUtc();
    return db
        .into(db.gameCollectionsTable)
        .insert(
          GameCollectionsTableCompanion.insert(
            id: id,
            userId: userId,
            platformGameId: platformGameId,
            medium: medium,
            deletedAt: Value(deletedAt),
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  Future<List<String>> gameIds() async =>
      (await db.select(db.gamesTable).get()).map((r) => r.id).toList()..sort();

  Future<List<String>> platformGameIds() async =>
      (await db.select(db.platformGamesTable).get()).map((r) => r.id).toList()
        ..sort();

  Future<List<String>> collectionGameRecords(String userId) async =>
      (await (db.select(db.gameAccessTable)..where(
                (t) =>
                    t.userId.equals(userId) &
                    t.source.equals(cacheAccessSourceCollection),
              ))
              .get())
          .map((r) => r.gameId)
          .toList()
        ..sort();

  Future<List<String>> collectionPlatformRecords(String userId) async =>
      (await (db.select(db.platformGameAccessTable)..where(
                (t) =>
                    t.userId.equals(userId) &
                    t.source.equals(cacheAccessSourceCollection),
              ))
              .get())
          .map((r) => r.platformGameId)
          .toList()
        ..sort();

  /// [count] games, each with one platform game, past one chunk with a
  /// partial last: ids `g-i` and `pg-i`.
  Future<void> seedMany(int count) async {
    final now = DateTime.now().toUtc();
    await db.batch((b) {
      b.insertAll(db.gamesTable, [
        for (var i = 0; i < count; i++)
          GamesTableCompanion.insert(
            id: 'g-$i',
            title: 'Game $i',
            createdAt: now,
            updatedAt: now,
          ),
      ]);
      b.insertAll(db.platformGamesTable, [
        for (var i = 0; i < count; i++)
          PlatformGamesTableCompanion.insert(
            id: 'pg-$i',
            gameId: 'g-$i',
            platformId: 'plat-1',
            platformName: 'Tabletop',
            createdAt: now,
            updatedAt: now,
          ),
      ]);
    });
  }

  group('prune', () {
    test('deletes a platform game and its game when nothing points at '
        'them', () async {
      await seedPlatformGame(db, id: 'pg-1', gameId: 'g-1');

      await access.prune(platformGameIds: {'pg-1'});

      expect(await platformGameIds(), isEmpty);
      expect(await gameIds(), isEmpty);
    });

    test("keeps a row another user's record points at", () async {
      await seedPlatformGame(db, id: 'pg-1', gameId: 'g-1');
      await gameRecord(_kUserB, 'g-1');
      await platformRecord(_kUserB, 'pg-1');

      await access.prune(gameIds: {'g-1'}, platformGameIds: {'pg-1'});

      expect(await platformGameIds(), ['pg-1']);
      expect(await gameIds(), ['g-1']);
    });

    test('keeps a platform game a collection row joins to, a tombstone '
        'included', () async {
      await seedPlatformGame(db, id: 'pg-1', gameId: 'g-1');
      await collectionRow(_kUserB, 'pg-1', deletedAt: DateTime.utc(2026, 10));

      await access.prune(gameIds: {'g-1'}, platformGameIds: {'pg-1'});

      expect(await platformGameIds(), ['pg-1']);
      expect(await gameIds(), ['g-1']);
    });

    test('keeps a game while one of its platform games stays', () async {
      await seedPlatformGame(db, id: 'pg-1', gameId: 'g-1');
      await seedPlatformGame(db, id: 'pg-2', gameId: 'g-1');
      await platformRecord(_kUserB, 'pg-2');

      await access.prune(platformGameIds: {'pg-1', 'pg-2'});

      expect(await platformGameIds(), ['pg-2']);
      expect(await gameIds(), ['g-1']);
    });

    test('leaves rows outside the ids it was given', () async {
      await seedPlatformGame(db, id: 'pg-1', gameId: 'g-1');
      await seedPlatformGame(db, id: 'pg-9', gameId: 'g-9');

      await access.prune(platformGameIds: {'pg-1'});

      expect(await platformGameIds(), ['pg-9']);
      expect(await gameIds(), ['g-9']);
    });

    test('prunes platform games and their games across chunks', () async {
      const count = 1203;
      await seedMany(count);

      await access.prune(
        platformGameIds: {for (var i = 0; i < count; i++) 'pg-$i'},
      );

      expect(await platformGameIds(), isEmpty);
      expect(await gameIds(), isEmpty);
    });

    test('binds more ids than one statement can hold', () async {
      const count = 40000;
      final now = DateTime.now().toUtc();
      await db.batch((b) {
        b.insertAll(db.gamesTable, [
          for (var i = 0; i < count; i++)
            GamesTableCompanion.insert(
              id: 'g-$i',
              title: 'Game $i',
              createdAt: now,
              updatedAt: now,
            ),
        ]);
      });

      await access.prune(gameIds: {for (var i = 0; i < count; i++) 'g-$i'});

      expect(await gameIds(), isEmpty);
    });
  });

  group('forgetGame', () {
    test("deletes the user's records and the rows no one else reads", () async {
      await seedPlatformGame(db, id: 'pg-1', gameId: 'g-1');
      await gameRecord(_kUserA, 'g-1');
      await gameRecord(_kUserA, 'g-1', cacheAccessSourceCollection);
      await platformRecord(_kUserA, 'pg-1');
      await platformRecord(_kUserA, 'pg-1', cacheAccessSourceCollection);

      await access.forgetGame(userId: _kUserA, gameId: 'g-1');

      expect(await db.select(db.gameAccessTable).get(), isEmpty);
      expect(await db.select(db.platformGameAccessTable).get(), isEmpty);
      expect(await platformGameIds(), isEmpty);
      expect(await gameIds(), isEmpty);
    });

    test("keeps the rows and records of another user's", () async {
      await seedPlatformGame(db, id: 'pg-1', gameId: 'g-1');
      for (final user in [_kUserA, _kUserB]) {
        await gameRecord(user, 'g-1');
        await platformRecord(user, 'pg-1');
      }

      await access.forgetGame(userId: _kUserA, gameId: 'g-1');

      expect(await platformGameIds(), ['pg-1']);
      expect(await gameIds(), ['g-1']);
      expect((await db.select(db.gameAccessTable).get()).map((r) => r.userId), [
        _kUserB,
      ]);
      expect(
        (await db.select(db.platformGameAccessTable).get()).map(
          (r) => r.userId,
        ),
        [_kUserB],
      );
    });

    test('binds more platform games than one statement can hold', () async {
      const count = 40000;
      final now = DateTime.now().toUtc();
      await seedGame(db, id: 'g-1');
      await db.batch((b) {
        b.insertAll(db.platformGamesTable, [
          for (var i = 0; i < count; i++)
            PlatformGamesTableCompanion.insert(
              id: 'pg-$i',
              gameId: 'g-1',
              platformId: 'plat-1',
              platformName: 'Tabletop',
              createdAt: now,
              updatedAt: now,
            ),
        ]);
      });
      await platformRecord(_kUserA, 'pg-0');

      await access.forgetGame(userId: _kUserA, gameId: 'g-1');

      expect(await db.select(db.platformGameAccessTable).get(), isEmpty);
      expect(await platformGameIds(), isEmpty);
      expect(await gameIds(), isEmpty);
    });
  });

  group('forgetCatalog', () {
    test("deletes the user's catalog records and prunes what they named, "
        'keeping what a collection record still reads', () async {
      await seedPlatformGame(db, id: 'pg-1', gameId: 'g-1');
      await seedPlatformGame(db, id: 'pg-2', gameId: 'g-2');
      await gameRecord(_kUserA, 'g-1');
      await platformRecord(_kUserA, 'pg-1');
      await gameRecord(_kUserA, 'g-2');
      await platformRecord(_kUserA, 'pg-2');
      await gameRecord(_kUserA, 'g-2', cacheAccessSourceCollection);
      await platformRecord(_kUserA, 'pg-2', cacheAccessSourceCollection);

      await access.forgetCatalog(userId: _kUserA);

      expect(await gameIds(), ['g-2']);
      expect(await platformGameIds(), ['pg-2']);
      expect(await collectionGameRecords(_kUserA), ['g-2']);
      expect(await collectionPlatformRecords(_kUserA), ['pg-2']);
      expect((await db.select(db.gameAccessTable).get()).map((r) => r.source), [
        cacheAccessSourceCollection,
      ]);
    });

    test("leaves another user's catalog records", () async {
      await seedPlatformGame(db, id: 'pg-1', gameId: 'g-1');
      await gameRecord(_kUserA, 'g-1');
      await gameRecord(_kUserB, 'g-1');
      await platformRecord(_kUserA, 'pg-1');
      await platformRecord(_kUserB, 'pg-1');

      await access.forgetCatalog(userId: _kUserA);

      expect(await gameIds(), ['g-1']);
      expect(await platformGameIds(), ['pg-1']);
    });
  });

  group('releaseCollection', () {
    test('does nothing for no platform games', () async {
      await seedPlatformGame(db, id: 'pg-1', gameId: 'g-1');
      await gameRecord(_kUserA, 'g-1', cacheAccessSourceCollection);

      await access.releaseCollection(userId: _kUserA, platformGameIds: {});

      expect(await collectionGameRecords(_kUserA), ['g-1']);
    });

    test('deletes the collection records and prunes the rows when the user '
        'has no collection row left', () async {
      await seedPlatformGame(db, id: 'pg-1', gameId: 'g-1');
      await gameRecord(_kUserA, 'g-1', cacheAccessSourceCollection);
      await platformRecord(_kUserA, 'pg-1', cacheAccessSourceCollection);

      await access.releaseCollection(
        userId: _kUserA,
        platformGameIds: {'pg-1'},
      );

      expect(await db.select(db.gameAccessTable).get(), isEmpty);
      expect(await db.select(db.platformGameAccessTable).get(), isEmpty);
      expect(await platformGameIds(), isEmpty);
      expect(await gameIds(), isEmpty);
    });

    test('keeps the game record while the user has a row on another '
        'platform game of it', () async {
      await seedPlatformGame(db, id: 'pg-1', gameId: 'g-1');
      await seedPlatformGame(db, id: 'pg-2', gameId: 'g-1');
      await gameRecord(_kUserA, 'g-1', cacheAccessSourceCollection);
      await platformRecord(_kUserA, 'pg-1', cacheAccessSourceCollection);
      await platformRecord(_kUserA, 'pg-2', cacheAccessSourceCollection);
      await collectionRow(_kUserA, 'pg-2');

      await access.releaseCollection(
        userId: _kUserA,
        platformGameIds: {'pg-1'},
      );

      expect(await collectionPlatformRecords(_kUserA), ['pg-2']);
      expect(await collectionGameRecords(_kUserA), ['g-1']);
      expect(await platformGameIds(), ['pg-2']);
      expect(await gameIds(), ['g-1']);
    });

    test('releases across chunks', () async {
      const count = 1203;
      await seedMany(count);
      await db.batch((b) {
        b.insertAll(db.gameAccessTable, [
          for (var i = 0; i < count; i++)
            GameAccessTableCompanion.insert(
              userId: _kUserA,
              gameId: 'g-$i',
              source: cacheAccessSourceCollection,
            ),
        ]);
        b.insertAll(db.platformGameAccessTable, [
          for (var i = 0; i < count; i++)
            PlatformGameAccessTableCompanion.insert(
              userId: _kUserA,
              platformGameId: 'pg-$i',
              source: cacheAccessSourceCollection,
            ),
        ]);
      });
      await collectionRow(_kUserA, 'pg-600');

      await access.releaseCollection(
        userId: _kUserA,
        platformGameIds: {for (var i = 0; i < count; i++) 'pg-$i'},
      );

      expect(await platformGameIds(), ['pg-600']);
      expect(await gameIds(), ['g-600']);
      expect(await collectionPlatformRecords(_kUserA), ['pg-600']);
      expect(await collectionGameRecords(_kUserA), ['g-600']);
    });

    test('keeps the records of a platform game the user still has a row '
        'on, a tombstone included', () async {
      await seedPlatformGame(db, id: 'pg-1', gameId: 'g-1');
      await gameRecord(_kUserA, 'g-1', cacheAccessSourceCollection);
      await platformRecord(_kUserA, 'pg-1', cacheAccessSourceCollection);
      await collectionRow(_kUserA, 'pg-1', deletedAt: DateTime.utc(2026, 10));

      await access.releaseCollection(
        userId: _kUserA,
        platformGameIds: {'pg-1'},
      );

      expect(await collectionPlatformRecords(_kUserA), ['pg-1']);
      expect(await collectionGameRecords(_kUserA), ['g-1']);
    });

    test("keeps a row another user's collection row points at", () async {
      await seedPlatformGame(db, id: 'pg-1', gameId: 'g-1');
      await gameRecord(_kUserA, 'g-1', cacheAccessSourceCollection);
      await platformRecord(_kUserA, 'pg-1', cacheAccessSourceCollection);
      await collectionRow(_kUserB, 'pg-1');

      await access.releaseCollection(
        userId: _kUserA,
        platformGameIds: {'pg-1'},
      );

      expect(await collectionPlatformRecords(_kUserA), isEmpty);
      expect(await collectionGameRecords(_kUserA), isEmpty);
      expect(await platformGameIds(), ['pg-1']);
      expect(await gameIds(), ['g-1']);
    });
  });
}
