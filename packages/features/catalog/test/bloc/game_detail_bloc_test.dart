import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_games_remote.dart';

void main() {
  late FakeGamesRemote remote;
  late ServerDatabase db;
  late GameRepositoryImpl cache;

  /// The games the bloc said were gone.
  late List<String> told;

  /// Whether the cache still held the last of them when the bloc said so.
  Future<bool>? cachedWhenTold;

  setUp(() {
    remote = FakeGamesRemote();
    db = inMemoryServerDatabase();
    cache = GameRepositoryImpl(db, userId: 'user-a');
    told = [];
    cachedWhenTold = null;
  });
  tearDown(() => db.close());

  GameDetailBloc build({String gameId = 'g_catan', bool withCache = true}) =>
      GameDetailBloc(
        gameId: gameId,
        remote: remote,
        cache: withCache ? cache : null,
        onGone: (id) {
          told.add(id);
          // Ignored unless awaited: a disposed cache cannot answer.
          cachedWhenTold = cache.getGames([id]).then((g) => g.isNotEmpty)
            ..ignore();
        },
      );

  final catan = game('g_catan', title: 'Catan');
  const tabletop = PlatformGameSummary(
    id: 'pg_1',
    platformId: 'plat_tabletop',
    platformName: 'Tabletop',
    game: GameSummary(id: 'g_catan', title: 'Catan'),
  );

  blocTest<GameDetailBloc, GameDetailState>(
    'shows the game and its platform games, and caches the game',
    setUp: () =>
        remote.onFetchGame = (_) async =>
            (game: catan, platformGames: [tabletop]),
    build: build,
    act: (bloc) => bloc.add(const GameDetailLoadRequested()),
    expect: () => [
      const GameDetailLoading(),
      GameDetailReady(game: catan, platformGames: const [tabletop]),
    ],
    verify: (_) async {
      expect(remote.calls, ['fetchGame(g_catan)']);
      expect(await cache.getGame('g_catan'), catan);
      expect(told, isEmpty);
    },
  );

  for (final (name, failure) in [
    ('a game the server does not have', const GameNotFoundException('404')),
    ('a game the user may not read', const GamesForbiddenException('403')),
  ]) {
    group(name, () {
      setUp(() async {
        await cache.cacheGame(catan);
        remote.onFetchGame = (_) async => throw failure;
      });

      blocTest<GameDetailBloc, GameDetailState>(
        'is unavailable, even when it is cached',
        build: build,
        act: (bloc) => bloc.add(const GameDetailLoadRequested()),
        expect: () => [
          const GameDetailLoading(),
          const GameDetailUnavailable(),
        ],
      );

      blocTest<GameDetailBloc, GameDetailState>(
        'is forgotten on this device, so offline browse and search stop '
        'listing it',
        build: build,
        act: (bloc) => bloc.add(const GameDetailLoadRequested()),
        verify: (_) async {
          expect(await cache.getGamesPage(limit: 10), isEmpty);
          expect(await cache.searchGames('catan'), isEmpty);
        },
      );

      blocTest<GameDetailBloc, GameDetailState>(
        'is said to be gone once it is forgotten, so the lists open take '
        'it down',
        build: build,
        act: (bloc) => bloc.add(const GameDetailLoadRequested()),
        verify: (_) async {
          expect(told, ['g_catan']);
          expect(await cachedWhenTold, isFalse);
        },
      );

      test('found gone after the detail closed is forgotten, but not said '
          'to be gone: the session it was asked for may have ended', () async {
        final answer = Completer<GameWithPlatformGames>();
        remote.onFetchGame = (_) => answer.future;
        final bloc = build()..add(const GameDetailLoadRequested());
        await pumpEventQueue();
        expect(remote.calls, ['fetchGame(g_catan)']);

        await bloc.close();
        answer.completeError(failure);
        await pumpEventQueue();

        expect(await cache.getGame('g_catan'), isNull);
        expect(told, isEmpty);
      });

      test('stays forgotten when a detail closed earlier is answered after '
          'it', () async {
        final older = Completer<GameWithPlatformGames>();
        remote.onFetchGame = (_) => older.future;
        final closed = build()..add(const GameDetailLoadRequested());
        await pumpEventQueue();
        await closed.close();

        remote.onFetchGame = (_) async => throw failure;
        final reopened = build()..add(const GameDetailLoadRequested());
        await pumpEventQueue();
        expect(await cache.getGame('g_catan'), isNull);

        older.complete((game: catan, platformGames: [tabletop]));
        await pumpEventQueue();

        expect(await cache.getGame('g_catan'), isNull);
        await reopened.close();
      });

      blocTest<GameDetailBloc, GameDetailState>(
        'is still unavailable when it cannot be forgotten',
        build: () {
          unawaited(cache.onDispose());
          return build();
        },
        act: (bloc) => bloc.add(const GameDetailLoadRequested()),
        expect: () => [
          const GameDetailLoading(),
          const GameDetailUnavailable(),
        ],
      );
    });
  }

  blocTest<GameDetailBloc, GameDetailState>(
    'an id that cannot name a game is unavailable',
    setUp: () =>
        remote.onFetchGame = (id) async => throw ArgumentError.value(id, 'id'),
    build: () => build(gameId: 'not/an/id'),
    act: (bloc) => bloc.add(const GameDetailLoadRequested()),
    expect: () => [const GameDetailLoading(), const GameDetailUnavailable()],
    // The server said nothing about it, so no list is told it is gone.
    verify: (_) => expect(told, isEmpty),
  );

  group('when the server cannot be reached', () {
    setUp(() => remote.onFetchGame = (_) async => throw unreachable());

    blocTest<GameDetailBloc, GameDetailState>(
      'shows the cached game, with no platform games to offer',
      setUp: () => cache.cacheGame(catan),
      build: build,
      act: (bloc) => bloc.add(const GameDetailLoadRequested()),
      expect: () => [
        const GameDetailLoading(),
        GameDetailReady(game: catan, fromCache: true),
      ],
    );

    blocTest<GameDetailBloc, GameDetailState>(
      'fails when the game is not cached',
      build: build,
      act: (bloc) => bloc.add(const GameDetailLoadRequested()),
      expect: () => [const GameDetailLoading(), const GameDetailFailed()],
    );

    blocTest<GameDetailBloc, GameDetailState>(
      'fails when there is no cache to read',
      build: () => build(withCache: false),
      act: (bloc) => bloc.add(const GameDetailLoadRequested()),
      expect: () => [const GameDetailLoading(), const GameDetailFailed()],
    );

    blocTest<GameDetailBloc, GameDetailState>(
      'a retry asks the server again',
      build: build,
      act: (bloc) async {
        bloc.add(const GameDetailLoadRequested());
        await pumpEventQueue();
        remote.onFetchGame = (_) async =>
            (game: catan, platformGames: const <PlatformGameSummary>[]);
        bloc.add(const GameDetailLoadRequested());
      },
      skip: 2,
      expect: () => [const GameDetailLoading(), GameDetailReady(game: catan)],
    );
  });
}
