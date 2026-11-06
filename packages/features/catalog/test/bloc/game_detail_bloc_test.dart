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
  final tabletop = PlatformGame(
    id: 'pg_1',
    gameId: 'g_catan',
    platformId: 'plat_tabletop',
    platformName: 'Tabletop',
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  blocTest<GameDetailBloc, GameDetailState>(
    'shows the game and its platform games, and caches both',
    setUp: () =>
        remote.onFetchGame = (_) async =>
            (game: catan, platformGames: [tabletop]),
    build: build,
    act: (bloc) => bloc.add(const GameDetailLoadRequested()),
    expect: () => [
      const GameDetailLoading(),
      GameDetailReady(game: catan, platformGames: [tabletop]),
    ],
    verify: (_) async {
      expect(remote.calls, ['fetchGame(g_catan)']);
      expect(await cache.getGame('g_catan'), catan);
      expect(await cache.getPlatformGame('pg_1'), tabletop);
      expect(told, isEmpty);
    },
  );

  group('caching the platform games', () {
    late _GatedCache gated;

    setUp(() {
      gated = _GatedCache(db, userId: 'user-a');
      remote.onFetchGame = (_) async =>
          (game: catan, platformGames: [tabletop]);
    });

    GameDetailBloc buildGated() =>
        GameDetailBloc(gameId: 'g_catan', remote: remote, cache: gated);

    test('caches no platform games once the detail has closed', () async {
      final gameWrite = Completer<void>();
      gated.beforeCacheGame = () => gameWrite.future;
      final bloc = buildGated()..add(const GameDetailLoadRequested());
      await pumpEventQueue();
      expect(gated.gameWrites, 1);

      await bloc.close();
      gameWrite.complete();
      await pumpEventQueue();

      expect(await cache.getPlatformGame('pg_1'), isNull);
      expect(gated.platformGameWrites, 0);
    });

    blocTest<GameDetailBloc, GameDetailState>(
      'a failed platform-game write still shows the detail',
      setUp: () =>
          gated.beforeCachePlatformGames = () async =>
              throw StateError('disposed'),
      build: buildGated,
      act: (bloc) => bloc.add(const GameDetailLoadRequested()),
      expect: () => [
        const GameDetailLoading(),
        GameDetailReady(game: catan, platformGames: [tabletop]),
      ],
      verify: (_) async => expect(await cache.getGame('g_catan'), catan),
    );

    blocTest<GameDetailBloc, GameDetailState>(
      'a failed game write skips the platform games, whose rows need the '
      'game',
      setUp: () =>
          gated.beforeCacheGame = () async => throw StateError('disposed'),
      build: buildGated,
      act: (bloc) => bloc.add(const GameDetailLoadRequested()),
      expect: () => [
        const GameDetailLoading(),
        GameDetailReady(game: catan, platformGames: [tabletop]),
      ],
      verify: (_) => expect(gated.platformGameWrites, 0),
    );

    blocTest<GameDetailBloc, GameDetailState>(
      'a game on no platform writes no platform games',
      setUp: () =>
          remote.onFetchGame = (_) async =>
              (game: catan, platformGames: const <PlatformGame>[]),
      build: buildGated,
      act: (bloc) => bloc.add(const GameDetailLoadRequested()),
      skip: 1,
      expect: () => [GameDetailReady(game: catan)],
      verify: (_) => expect(gated.platformGameWrites, 0),
    );
  });

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
      'shows the cached game, with no platform games when none are cached',
      setUp: () => cache.cacheGame(catan),
      build: build,
      act: (bloc) => bloc.add(const GameDetailLoadRequested()),
      expect: () => [
        const GameDetailLoading(),
        GameDetailReady(game: catan, fromCache: true),
      ],
    );

    // So the page can say what the user owns and offer an add offline
    // (#708).
    blocTest<GameDetailBloc, GameDetailState>(
      'shows the cached game with the platform games cached for it',
      setUp: () async {
        await cache.cacheGame(catan);
        await cache.cachePlatformGames([tabletop]);
      },
      build: build,
      act: (bloc) => bloc.add(const GameDetailLoadRequested()),
      expect: () => [
        const GameDetailLoading(),
        isA<GameDetailReady>()
            .having((s) => s.game, 'game', catan)
            .having((s) => s.fromCache, 'fromCache', isTrue)
            .having(
              (s) => s.platformGames.map((p) => p.id),
              'platform game ids',
              ['pg_1'],
            ),
      ],
    );

    test('shows the cached game with no platform games when reading them '
        'fails', () async {
      final failing = _GatedCache(db, userId: 'user-a')
        ..platformGamesReadError = StateError('the read failed');
      await failing.cacheGame(catan);
      final bloc = GameDetailBloc(
        gameId: 'g_catan',
        remote: remote,
        cache: failing,
      );
      addTearDown(bloc.close);

      bloc.add(const GameDetailLoadRequested());
      await pumpEventQueue();

      expect(bloc.state, GameDetailReady(game: catan, fromCache: true));
    });

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
            (game: catan, platformGames: const <PlatformGame>[]);
        bloc.add(const GameDetailLoadRequested());
      },
      skip: 2,
      expect: () => [const GameDetailLoading(), GameDetailReady(game: catan)],
    );
  });
}

/// The real games cache, with a hook before each write the bloc makes, and a
/// count of them.
class _GatedCache extends GameRepositoryImpl {
  _GatedCache(super.db, {required super.userId});

  Future<void> Function()? beforeCacheGame;
  Future<void> Function()? beforeCachePlatformGames;
  int gameWrites = 0;
  int platformGameWrites = 0;

  /// Thrown by [getPlatformGamesForGame] when set.
  Object? platformGamesReadError;

  @override
  Future<List<PlatformGame>> getPlatformGamesForGame(String gameId) async {
    if (platformGamesReadError case final error?) throw error;
    return super.getPlatformGamesForGame(gameId);
  }

  @override
  Future<void> cacheGame(Game game) async {
    gameWrites++;
    await beforeCacheGame?.call();
    return super.cacheGame(game);
  }

  @override
  Future<void> cachePlatformGames(List<PlatformGame> platformGames) async {
    platformGameWrites++;
    await beforeCachePlatformGames?.call();
    return super.cachePlatformGames(platformGames);
  }
}
