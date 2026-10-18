import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_repository_impl.dart';

const _kUserA = 'user-a';
const _kUserB = 'user-b';

final _seeded = DateTime.utc(2026, 10, 1);

Game _game({String id = 'g-1', String title = 'Brass: Birmingham'}) =>
    Game(id: id, title: title, createdAt: _seeded, updatedAt: _seeded);

PlatformGame _platformGame({String id = 'pg-1', String gameId = 'g-1'}) =>
    PlatformGame(
      id: id,
      gameId: gameId,
      platformId: 'plat-$id',
      platformName: 'Platform $id',
      createdAt: _seeded,
      updatedAt: _seeded,
    );

PlatformGameSummary _summary({String id = 'pg-1', String gameId = 'g-1'}) =>
    PlatformGameSummary(
      id: id,
      platformId: 'plat-$id',
      platformName: 'Platform $id',
      game: GameSummary(id: gameId, title: 'Brass: Birmingham'),
    );

/// Every read the repository has, as what it returned, so a test can say in
/// one line that a user sees nothing of a game.
Future<List<Object?>> _everyRead(GameRepositoryImpl repo) async => [
  await repo.getGame('g-1'),
  await repo.getGames(['g-1']),
  await repo.searchGames('brass'),
  await repo.watchGame('g-1').first,
  await repo.watchGames().first,
  await repo.getPlatformGame('pg-1'),
  await repo.getPlatformGamesForGame('g-1'),
];

const _seesNothing = [
  null,
  <Game>[],
  <Game>[],
  null,
  <Game>[],
  null,
  <PlatformGame>[],
];

/// The cache is one set of tables per server, shared by every user signed
/// in to it on this device; each read returns only what was cached for its
/// own user (#434).
void main() {
  late ServerDatabase db;

  setUp(() => db = inMemoryServerDatabase());
  tearDown(() => db.close());

  GameRepositoryImpl repoFor(String userId) =>
      GameRepositoryImpl(db, userId: userId);

  test('B reads nothing cached for A, through every read', () async {
    final a = repoFor(_kUserA);
    await a.cacheGame(_game());
    await a.cachePlatformGame(_platformGame());

    expect(await _everyRead(repoFor(_kUserB)), _seesNothing);
    expect(await a.getGame('g-1'), isNotNull);
    expect(await a.getPlatformGame('pg-1'), isNotNull);
  });

  test('a summary records the game for its user, so a full record cached '
      'later by another user is readable to them both', () async {
    final a = repoFor(_kUserA);
    final b = repoFor(_kUserB);
    await a.cachePlatformGameSummaries([_summary()]);

    await b.cacheGame(_game());
    await b.cachePlatformGame(_platformGame());

    expect((await a.getGame('g-1'))?.title, 'Brass: Birmingham');
    expect((await a.getPlatformGame('pg-1'))?.id, 'pg-1');
    expect((await b.getGame('g-1'))?.title, 'Brass: Birmingham');
  });

  test("B doesn't see A's platform game for a game they share", () async {
    final a = repoFor(_kUserA);
    final b = repoFor(_kUserB);
    await a.cacheGame(_game());
    await a.cachePlatformGame(_platformGame(id: 'pg-a'));
    await b.cacheGame(_game());
    await b.cachePlatformGame(_platformGame(id: 'pg-b'));

    expect((await b.getPlatformGamesForGame('g-1')).map((pg) => pg.id), [
      'pg-b',
    ]);
    expect(await b.getPlatformGame('pg-a'), isNull);
  });

  test(
    'caching a game records the game only, not its platform games',
    () async {
      final a = repoFor(_kUserA);
      final b = repoFor(_kUserB);
      await a.cacheGame(_game());
      await a.cachePlatformGame(_platformGame());

      await b.cacheGames([_game()]);

      expect(await b.getGame('g-1'), isNotNull);
      expect(await b.getPlatformGamesForGame('g-1'), isEmpty);
    },
  );

  test('watchGames re-emits when the user gains a game another user had '
      'already cached', () async {
    final a = repoFor(_kUserA);
    final b = repoFor(_kUserB);
    await a.cacheGame(_game());

    final emissions = b.watchGames().take(2).toList();
    await pumpEventQueue();
    await b.cacheGames([_game()]);

    final ids = [
      for (final games in await emissions.timeout(const Duration(seconds: 5)))
        [for (final game in games) game.id],
    ];
    expect(ids, [
      <String>[],
      ['g-1'],
    ]);
  });
}
