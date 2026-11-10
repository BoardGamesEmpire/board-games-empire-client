import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

const _kUser = 'user-a';

final _seeded = DateTime.utc(2026, 10);

Game _game(
  String id,
  String title, {
  DateTime? deletedAt,
  DateTime? createdAt,
}) => Game(
  id: id,
  title: title,
  deletedAt: deletedAt,
  createdAt: createdAt ?? _seeded,
  updatedAt: _seeded,
);

/// The cache's catalog read, for offline browse (#42): the games cached for
/// this user, a page at a time, in the order `GET /games` pages them, by title
/// or newest first (#615).
void main() {
  late ServerDatabase db;
  late GameRepositoryImpl repo;

  setUp(() {
    db = inMemoryServerDatabase();
    repo = GameRepositoryImpl(db, userId: _kUser);
  });
  tearDown(() => db.close());

  Future<List<String>> idsOf(Future<List<Game>> page) async =>
      (await page).map((g) => g.id).toList();

  test('reads by title, then by id where titles tie', () async {
    await repo.cacheGames([
      _game('g-3', 'Wingspan'),
      _game('g-2', 'Azul'),
      _game('g-9', 'Catan'),
      _game('g-1', 'Catan'),
    ]);

    expect(await idsOf(repo.getGamesPage(limit: 10)), [
      'g-2',
      'g-1',
      'g-9',
      'g-3',
    ]);
  });

  test('orders titles without regard to case', () async {
    await repo.cacheGames([
      _game('g-1', 'azul'),
      _game('g-2', 'Brass'),
      _game('g-3', 'Agricola'),
    ]);

    expect(await idsOf(repo.getGamesPage(limit: 10)), ['g-3', 'g-1', 'g-2']);
  });

  test('pages by offset and limit', () async {
    await repo.cacheGames([
      for (var i = 0; i < 5; i++) _game('g-$i', 'Game $i'),
    ]);

    expect(await idsOf(repo.getGamesPage(limit: 2)), ['g-0', 'g-1']);
    expect(await idsOf(repo.getGamesPage(offset: 2, limit: 2)), ['g-2', 'g-3']);
    expect(await idsOf(repo.getGamesPage(offset: 4, limit: 2)), ['g-4']);
    expect(await idsOf(repo.getGamesPage(offset: 6, limit: 2)), isEmpty);
  });

  test(
    'leaves out tombstones and summary-only rows, as every read does',
    () async {
      await repo.cacheGames([
        _game('g-live', 'Azul'),
        _game('g-gone', 'Brass', deletedAt: _seeded),
      ]);
      await repo.cachePlatformGameSummaries([
        const PlatformGameSummary(
          id: 'pg-1',
          platformId: 'plat-1',
          platformName: 'Tabletop',
          game: GameSummary(id: 'g-summary', title: 'Catan'),
        ),
      ]);

      expect(await idsOf(repo.getGamesPage(limit: 10)), ['g-live']);
    },
  );

  test('title order is unchanged by default', () async {
    await repo.cacheGames([
      _game('g-1', 'Wingspan', createdAt: DateTime.utc(2026, 10, 3)),
      _game('g-2', 'Azul', createdAt: DateTime.utc(2026, 10)),
      _game('g-3', 'Catan', createdAt: DateTime.utc(2026, 10, 2)),
    ]);

    final byDefault = await idsOf(repo.getGamesPage(limit: 10));

    expect(byDefault, ['g-2', 'g-3', 'g-1']);
    expect(
      await idsOf(repo.getGamesPage(limit: 10)),
      byDefault,
    );
  });

  group('newest', () {
    Future<List<String>> newest({int offset = 0, int limit = 10}) => idsOf(
      repo.getGamesPage(offset: offset, limit: limit, sort: GameSort.newest),
    );

    test('orders by createdAt desc, then id desc', () async {
      await repo.cacheGames([
        _game('g-1', 'Azul', createdAt: DateTime.utc(2026, 10)),
        _game('g-4', 'Brass', createdAt: DateTime.utc(2026, 10, 3)),
        _game('g-2', 'Catan', createdAt: DateTime.utc(2026, 10, 2)),
        _game('g-3', 'Dune', createdAt: DateTime.utc(2026, 10, 2)),
        _game('g-5', 'Everdell', createdAt: DateTime.utc(2026, 10, 2)),
      ]);

      // Rows tied on createdAt come back id desc.
      expect(await newest(), ['g-4', 'g-5', 'g-3', 'g-2', 'g-1']);
    });

    test('does not order by title', () async {
      await repo.cacheGames([
        _game('g-1', 'Azul', createdAt: DateTime.utc(2026, 10)),
        _game('g-2', 'Brass', createdAt: DateTime.utc(2026, 10, 2)),
      ]);

      expect(await newest(), ['g-2', 'g-1']);
    });

    test('pages by offset and limit', () async {
      await repo.cacheGames([
        for (var i = 0; i < 5; i++)
          _game('g-$i', 'Game', createdAt: DateTime.utc(2026, 10, 1 + i)),
      ]);

      expect(await newest(limit: 2), ['g-4', 'g-3']);
      expect(await newest(offset: 2, limit: 2), ['g-2', 'g-1']);
      expect(await newest(offset: 4, limit: 2), ['g-0']);
    });

    test('skips summary-only rows', () async {
      await repo.cacheGames([
        _game('g-live', 'Azul', createdAt: DateTime.utc(2026, 10)),
      ]);
      // A collection summary stamps the row with this device's clock, which
      // is later than any seeded createdAt, so an unfiltered read would put
      // it first.
      await repo.cachePlatformGameSummaries([
        const PlatformGameSummary(
          id: 'pg-1',
          platformId: 'plat-1',
          platformName: 'Tabletop',
          game: GameSummary(id: 'g-summary', title: 'Catan'),
        ),
      ]);

      expect(await newest(), ['g-live']);
    });

    test('leaves out tombstones', () async {
      await repo.cacheGames([
        _game('g-live', 'Azul', createdAt: DateTime.utc(2026, 10)),
        _game(
          'g-gone',
          'Brass',
          createdAt: DateTime.utc(2026, 10, 2),
          deletedAt: _seeded,
        ),
      ]);

      expect(await newest(), ['g-live']);
    });
  });

  test('refuses a negative offset or a limit below one', () {
    expect(() => repo.getGamesPage(offset: -1, limit: 1), throwsArgumentError);
    expect(() => repo.getGamesPage(limit: 0), throwsArgumentError);
  });
}
