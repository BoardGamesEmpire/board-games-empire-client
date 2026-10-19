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

  /// A page a test answers by hand.
  late Completer<PaginatedResult<Game>> nextPage;

  setUp(() {
    remote = FakeGamesRemote();
    db = inMemoryServerDatabase();
    cache = GameRepositoryImpl(db, userId: 'user-a');
  });
  tearDown(() => db.close());

  /// Two games a page, so paging shows with few rows.
  GameBrowseBloc build({bool withCache = true}) => GameBrowseBloc(
    remote: remote,
    cache: withCache ? cache : null,
    pageSize: 2,
  );

  final azul = game('g_azul', title: 'Azul');
  final brass = game('g_brass', title: 'Brass');
  final catan = game('g_catan', title: 'Catan');

  group('online', () {
    blocTest<GameBrowseBloc, GameBrowseState>(
      'shows the first page, and caches it',
      setUp: () =>
          remote.onFetchPage = (_, _) async =>
              pageOf([azul, brass], hasMore: true),
      build: build,
      act: (bloc) => bloc.add(const GameBrowseLoadRequested()),
      expect: () => [
        const GameBrowseLoading(),
        GameBrowseReady(games: [azul, brass], hasMore: true),
      ],
      verify: (_) async {
        expect(remote.calls, ['fetchPage(1, 2)']);
        expect(await cache.getGames(['g_azul', 'g_brass']), hasLength(2));
      },
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'loads the next page onto the end',
      setUp: () => remote.onFetchPage = (page, _) async => page == 1
          ? pageOf([azul, brass], hasMore: true)
          : pageOf([catan], page: 2),
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
      },
      skip: 2,
      expect: () => [
        GameBrowseReady(games: [azul, brass], hasMore: true, loadingMore: true),
        GameBrowseReady(games: [azul, brass, catan]),
      ],
      verify: (_) =>
          expect(remote.calls, ['fetchPage(1, 2)', 'fetchPage(2, 2)']),
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'skips a game a page repeats, after the catalog shifted under it',
      setUp: () => remote.onFetchPage = (page, _) async => page == 1
          ? pageOf([azul, brass], hasMore: true)
          : pageOf([brass, catan], page: 2),
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
      },
      skip: 3,
      expect: () => [
        GameBrowseReady(games: [azul, brass, catan]),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'keeps the rows when the next page fails, and asks for it again',
      setUp: () {
        var failNext = true;
        remote.onFetchPage = (page, _) async {
          if (page == 1) return pageOf([azul, brass], hasMore: true);
          if (failNext) {
            failNext = false;
            throw unreachable();
          }
          return pageOf([catan], page: 2);
        };
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
      },
      skip: 3,
      expect: () => [
        GameBrowseReady(
          games: [azul, brass],
          hasMore: true,
          loadMoreFailed: true,
        ),
        GameBrowseReady(games: [azul, brass], hasMore: true, loadingMore: true),
        GameBrowseReady(games: [azul, brass, catan]),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'asks for nothing more at the end of the catalog',
      setUp: () => remote.onFetchPage = (_, _) async => pageOf([azul]),
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
      },
      verify: (_) => expect(remote.calls, ['fetchPage(1, 2)']),
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'ends the list where the server stops paging, whatever it says is left',
      setUp: () =>
          remote.onFetchPage = (page, _) async =>
              pageOf([game('g_$page')], page: page, hasMore: true),
      // Page 3 starts at the deepest row the server pages to.
      build: () => GameBrowseBloc(
        remote: remote,
        pageSize: GamesRemoteDataSource.maxDepth ~/ 2,
      ),
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        for (var i = 0; i < 3; i++) {
          await pumpEventQueue();
          bloc.add(const GameBrowseMoreRequested());
        }
      },
      verify: (bloc) {
        expect(remote.calls.map((c) => c.split(',').first), [
          'fetchPage(1',
          'fetchPage(2',
          'fetchPage(3',
        ]);
        expect((bloc.state as GameBrowseReady).hasMore, isFalse);
      },
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'an empty catalog is empty, whatever the cache holds',
      setUp: () async {
        await cache.cacheGames([azul]);
        remote.onFetchPage = (_, _) async => pageOf([]);
      },
      build: build,
      act: (bloc) => bloc.add(const GameBrowseLoadRequested()),
      expect: () => [const GameBrowseLoading(), const GameBrowseReady()],
    );
  });

  group('when the server cannot be reached', () {
    setUp(() => remote.onFetchPage = (_, _) async => throw unreachable());

    blocTest<GameBrowseBloc, GameBrowseState>(
      'shows the cached games in the catalog\'s order',
      setUp: () => cache.cacheGames([catan, azul, brass]),
      build: build,
      act: (bloc) => bloc.add(const GameBrowseLoadRequested()),
      expect: () => [
        const GameBrowseLoading(),
        GameBrowseReady(games: [azul, brass], hasMore: true, fromCache: true),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'reads the next page from the cache too',
      setUp: () => cache.cacheGames([catan, azul, brass]),
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
      },
      skip: 3,
      expect: () => [
        GameBrowseReady(games: [azul, brass, catan], fromCache: true),
      ],
      verify: (_) => expect(remote.calls, ['fetchPage(1, 2)']),
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'fails when the cache holds nothing',
      build: build,
      act: (bloc) => bloc.add(const GameBrowseLoadRequested()),
      expect: () => [const GameBrowseLoading(), const GameBrowseFailed()],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'fails when there is no cache to read',
      build: () => build(withCache: false),
      act: (bloc) => bloc.add(const GameBrowseLoadRequested()),
      expect: () => [const GameBrowseLoading(), const GameBrowseFailed()],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a retry that reaches the server replaces the cached rows',
      setUp: () => cache.cacheGames([azul]),
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        remote.onFetchPage = (_, _) async => pageOf([brass, catan]);
        bloc.add(const GameBrowseLoadRequested());
      },
      skip: 2,
      expect: () => [
        GameBrowseReady(games: [azul], fromCache: true, retrying: true),
        GameBrowseReady(games: [brass, catan]),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a retry shows that it is asking, and one that fails keeps every row '
      'shown',
      setUp: () => cache.cacheGames([catan, azul, brass]),
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseLoadRequested());
      },
      skip: 4,
      expect: () => [
        GameBrowseReady(
          games: [azul, brass, catan],
          fromCache: true,
          retrying: true,
        ),
        GameBrowseReady(games: [azul, brass, catan], fromCache: true),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a retry that fails keeps the rows when the cache can no longer be read',
      setUp: () => cache.cacheGames([azul]),
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        await cache.onDispose();
        bloc.add(const GameBrowseLoadRequested());
      },
      skip: 2,
      expect: () => [
        GameBrowseReady(games: [azul], fromCache: true, retrying: true),
        GameBrowseReady(games: [azul], fromCache: true),
      ],
    );
  });

  group('when the server refuses', () {
    const refused = GamesForbiddenException('403');

    blocTest<GameBrowseBloc, GameBrowseState>(
      'says the user may not browse, rather than showing the cache',
      setUp: () async {
        await cache.cacheGames([azul]);
        remote.onFetchPage = (_, _) async => throw refused;
      },
      build: build,
      act: (bloc) => bloc.add(const GameBrowseLoadRequested()),
      expect: () => [const GameBrowseLoading(), const GameBrowseDenied()],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'takes down the cached rows when a retry is refused',
      setUp: () async {
        await cache.cacheGames([azul]);
        remote.onFetchPage = (_, _) async => throw unreachable();
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        remote.onFetchPage = (_, _) async => throw refused;
        bloc.add(const GameBrowseLoadRequested());
      },
      skip: 3,
      expect: () => [const GameBrowseDenied()],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'takes down the pages already shown when a later page is refused',
      setUp: () =>
          remote.onFetchPage = (page, _) async =>
              page == 1 ? pageOf([azul, brass], hasMore: true) : throw refused,
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
      },
      skip: 3,
      expect: () => [const GameBrowseDenied()],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a retry after a refused page starts the catalog from the top',
      setUp: () =>
          remote.onFetchPage = (page, _) async =>
              page == 1 ? pageOf([azul, brass], hasMore: true) : throw refused,
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
        await pumpEventQueue();
        remote.onFetchPage = (_, _) async => pageOf([catan]);
        bloc.add(const GameBrowseLoadRequested());
      },
      skip: 4,
      expect: () => [
        const GameBrowseLoading(),
        GameBrowseReady(games: [catan]),
      ],
    );
  });

  group('a game found gone', () {
    blocTest<GameBrowseBloc, GameBrowseState>(
      'is taken down, and the rest of the list stays as it was',
      setUp: () =>
          remote.onFetchPage = (_, _) async =>
              pageOf([azul, brass], hasMore: true),
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseGameGone('g_azul'));
      },
      skip: 2,
      expect: () => [
        GameBrowseReady(games: [brass], hasMore: true),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'is taken down while the next page loads, not dropped behind it',
      setUp: () {
        final next = Completer<PaginatedResult<Game>>();
        remote.onFetchPage = (page, _) async =>
            page == 1 ? pageOf([azul, brass], hasMore: true) : next.future;
        addTearDown(() {
          if (!next.isCompleted) next.complete(pageOf([]));
        });
        nextPage = next;
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseGameGone('g_azul'));
        await pumpEventQueue();
        nextPage.complete(pageOf([catan], page: 2));
      },
      skip: 3,
      expect: () => [
        GameBrowseReady(games: [brass], hasMore: true, loadingMore: true),
        GameBrowseReady(games: [brass, catan]),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'that the list does not hold changes nothing',
      setUp: () => remote.onFetchPage = (_, _) async => pageOf([azul]),
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseGameGone('g_elsewhere'));
      },
      skip: 2,
      expect: () => <GameBrowseState>[],
    );
  });
}
