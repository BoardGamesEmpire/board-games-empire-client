import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/catalog_app.dart';
import '../support/fake_games_remote.dart';

/// A cache that cannot forget, as a session ending mid-refusal would leave it.
class _FailingForgetCache extends FakeGamesCache {
  @override
  Future<void> forgetCatalog() async => throw StateError('disposed');
}

/// A cache whose writes wait until the test lets them through, as one on a
/// busy disk does.
class _HeldWriteCache extends FakeGamesCache {
  final Completer<void> release = Completer<void>();

  @override
  Future<void> cacheGames(List<Game> games) => release.future;
}

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
  GameBrowseBloc build({
    bool withCache = true,
    Stream<String>? gone,
    GameSort sort = GameSort.title,
  }) => GameBrowseBloc(
    remote: remote,
    cache: withCache ? cache : null,
    gone: gone,
    initialSort: sort,
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
      "shows the cached games in the catalog's order",
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
      "a refusal forgets this user's catalog, so a retry that fails shows "
      'nothing cached',
      setUp: () async {
        await cache.cacheGames([azul]);
        remote.onFetchPage = (_, _) async => throw refused;
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        remote.onFetchPage = (_, _) async => throw unreachable();
        bloc.add(const GameBrowseLoadRequested());
      },
      expect: () => [
        const GameBrowseLoading(),
        const GameBrowseDenied(),
        const GameBrowseLoading(),
        const GameBrowseFailed(),
      ],
    );

    test('a screen opened again offline after a refusal shows nothing '
        'cached', () async {
      await cache.cacheGames([azul]);
      remote.onFetchPage = (_, _) async => throw refused;
      final first = build()..add(const GameBrowseLoadRequested());
      await first.stream.firstWhere((s) => s is GameBrowseDenied);
      await first.close();

      remote.onFetchPage = (_, _) async => throw unreachable();
      final second = build();
      addTearDown(second.close);
      final states = <GameBrowseState>[];
      final sub = second.stream.listen(states.add);
      addTearDown(sub.cancel);
      second.add(const GameBrowseLoadRequested());
      await pumpEventQueue();

      expect(states, [const GameBrowseLoading(), const GameBrowseFailed()]);
    });

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a refused later page forgets the catalog too',
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
      verify: (_) async => expect(await cache.getGamesPage(limit: 10), isEmpty),
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a refusal keeps games this user reaches through their collection',
      setUp: () async {
        await cache.cachePlatformGameSummaries([
          const PlatformGameSummary(
            id: 'pg_azul',
            platformId: 'plat_1',
            platformName: 'Platform',
            game: GameSummary(id: 'g_azul', title: 'Azul'),
          ),
        ]);
        await cache.cacheGames([azul]);
        remote.onFetchPage = (_, _) async => throw refused;
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        remote.onFetchPage = (_, _) async => throw unreachable();
        bloc.add(const GameBrowseLoadRequested());
      },
      skip: 3,
      expect: () => [
        GameBrowseReady(games: [azul], fromCache: true),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'still says the user may not browse when forgetting fails',
      setUp: () => remote.onFetchPage = (_, _) async => throw refused,
      build: () => GameBrowseBloc(
        remote: remote,
        cache: _FailingForgetCache(),
        pageSize: 2,
      ),
      act: (bloc) => bloc.add(const GameBrowseLoadRequested()),
      expect: () => [const GameBrowseLoading(), const GameBrowseDenied()],
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

  group('sort', () {
    // Added in this order, and told apart by when, not by title.
    final oldest = game(
      'g_oldest',
      title: 'Azul',
    ).copyWith(createdAt: DateTime.utc(2026));
    final middle = game(
      'g_middle',
      title: 'Catan',
    ).copyWith(createdAt: DateTime.utc(2026, 2));
    final newest = game(
      'g_newest',
      title: 'Brass',
    ).copyWith(createdAt: DateTime.utc(2026, 3));

    late _HeldWriteCache held;

    /// A read a test answers when it likes, by hand.
    Completer<PaginatedResult<Game>> hang() {
      final read = Completer<PaginatedResult<Game>>();
      addTearDown(() {
        if (!read.isCompleted) read.complete(pageOf([]));
      });
      return read;
    }

    /// Answers a title read with [title], and a newest one with [recent].
    Future<PaginatedResult<Game>> Function(int, int) bySort({
      required Future<PaginatedResult<Game>> Function(int page) title,
      required Future<PaginatedResult<Game>> Function(int page) recent,
    }) =>
        (page, _) =>
            remote.calls.last.endsWith('newest)') ? recent(page) : title(page);

    blocTest<GameBrowseBloc, GameBrowseState>(
      'reads with initialSort',
      setUp: () =>
          remote.onFetchPage = (_, _) async => pageOf([newest, middle]),
      build: () => build(sort: GameSort.newest),
      act: (bloc) => bloc.add(const GameBrowseLoadRequested()),
      expect: () => [
        const GameBrowseLoading(sort: GameSort.newest),
        GameBrowseReady(games: [newest, middle], sort: GameSort.newest),
      ],
      verify: (_) => expect(remote.calls, ['fetchPage(1, 2, newest)']),
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a sort change reads page 1 in the new order',
      setUp: () => remote.onFetchPage = bySort(
        title: (_) async => pageOf([oldest, newest], hasMore: true),
        recent: (_) async => pageOf([newest, middle], hasMore: true),
      ),
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseSortChanged(GameSort.newest));
      },
      skip: 2,
      expect: () => [
        const GameBrowseLoading(sort: GameSort.newest),
        GameBrowseReady(
          games: [newest, middle],
          hasMore: true,
          sort: GameSort.newest,
        ),
      ],
      verify: (_) =>
          expect(remote.calls, ['fetchPage(1, 2)', 'fetchPage(1, 2, newest)']),
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a sort change drops the pages shown, and a game found gone stays down',
      setUp: () => remote.onFetchPage = bySort(
        title: (_) async => pageOf([oldest, newest], hasMore: true),
        recent: (_) async => pageOf([newest, middle]),
      ),
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseGameGone('g_newest'));
        await pumpEventQueue();
        bloc.add(const GameBrowseSortChanged(GameSort.newest));
      },
      skip: 3,
      expect: () => [
        const GameBrowseLoading(sort: GameSort.newest),
        GameBrowseReady(games: [middle], sort: GameSort.newest),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a sort change while a page loads is not dropped, and the old answer is '
      'discarded',
      setUp: () {
        final title = hang();
        remote.onFetchPage = bySort(
          title: (_) => title.future,
          recent: (_) async => pageOf([newest, middle]),
        );
        nextPage = title;
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseSortChanged(GameSort.newest));
        await pumpEventQueue();
        // The title order's page lands after the change.
        nextPage.complete(pageOf([oldest, newest]));
      },
      expect: () => [
        const GameBrowseLoading(),
        const GameBrowseLoading(sort: GameSort.newest),
        GameBrowseReady(games: [newest, middle], sort: GameSort.newest),
      ],
      verify: (_) async {
        // Neither shown nor cached.
        expect(await cache.getGames(['g_oldest']), isEmpty);
        expect(await cache.getGames(['g_newest', 'g_middle']), hasLength(2));
      },
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a page already answered, still being cached when the sort changes, is '
      'discarded',
      setUp: () => remote.onFetchPage = bySort(
        title: (_) async => pageOf([oldest, newest]),
        recent: (_) async => pageOf([newest, middle]),
      ),
      build: () {
        held = _HeldWriteCache();
        return GameBrowseBloc(remote: remote, cache: held, pageSize: 2);
      },
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseSortChanged(GameSort.newest));
        await pumpEventQueue();
        held.release.complete();
      },
      expect: () => [
        const GameBrowseLoading(),
        const GameBrowseLoading(sort: GameSort.newest),
        GameBrowseReady(games: [newest, middle], sort: GameSort.newest),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a next page on its way when the sort changes is discarded too',
      setUp: () {
        final title = hang();
        remote.onFetchPage = bySort(
          title: (page) => page == 1
              ? Future.value(pageOf([oldest, newest], hasMore: true))
              : title.future,
          recent: (_) async => pageOf([newest, middle]),
        );
        nextPage = title;
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseSortChanged(GameSort.newest));
        await pumpEventQueue();
        nextPage.complete(pageOf([middle], page: 2));
      },
      skip: 3,
      expect: () => [
        const GameBrowseLoading(sort: GameSort.newest),
        GameBrowseReady(games: [newest, middle], sort: GameSort.newest),
      ],
      verify: (_) async =>
          expect(await cache.getGames(['g_middle']), hasLength(1)),
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a late 403 for the old sort is ignored',
      setUp: () async {
        await cache.cacheGames([oldest]);
        final title = hang();
        remote.onFetchPage = bySort(
          title: (_) => title.future,
          recent: (_) async => pageOf([newest, middle]),
        );
        nextPage = title;
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseSortChanged(GameSort.newest));
        await pumpEventQueue();
        nextPage.completeError(const GamesForbiddenException('403'));
      },
      expect: () => [
        const GameBrowseLoading(),
        const GameBrowseLoading(sort: GameSort.newest),
        GameBrowseReady(games: [newest, middle], sort: GameSort.newest),
      ],
      verify: (_) async {
        // The catalog was not forgotten on its word.
        expect(await cache.getGames(['g_oldest']), hasLength(1));
      },
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a late failure for the old sort is ignored',
      setUp: () {
        final title = hang();
        remote.onFetchPage = bySort(
          title: (_) => title.future,
          recent: (_) async => pageOf([newest, middle]),
        );
        nextPage = title;
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseSortChanged(GameSort.newest));
        await pumpEventQueue();
        nextPage.completeError(unreachable());
      },
      expect: () => [
        const GameBrowseLoading(),
        const GameBrowseLoading(sort: GameSort.newest),
        GameBrowseReady(games: [newest, middle], sort: GameSort.newest),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'the same sort does nothing',
      setUp: () => remote.onFetchPage = (_, _) async => pageOf([azul]),
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseSortChanged(GameSort.title));
      },
      skip: 2,
      expect: () => <GameBrowseState>[],
      verify: (_) => expect(remote.calls, ['fetchPage(1, 2)']),
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'asking again for the sort being read does not stop that read',
      setUp: () {
        final recent = hang();
        remote.onFetchPage = bySort(
          title: (_) async => pageOf([oldest]),
          recent: (_) => recent.future,
        );
        nextPage = recent;
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseSortChanged(GameSort.newest));
        await pumpEventQueue();
        bloc.add(const GameBrowseSortChanged(GameSort.newest));
        await pumpEventQueue();
        nextPage.complete(pageOf([newest]));
      },
      skip: 2,
      expect: () => [
        const GameBrowseLoading(sort: GameSort.newest),
        GameBrowseReady(games: [newest], sort: GameSort.newest),
      ],
      verify: (_) =>
          expect(remote.calls, ['fetchPage(1, 2)', 'fetchPage(1, 2, newest)']),
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'two changes while a read is out show the last one',
      setUp: () {
        final recent = hang();
        remote.onFetchPage = bySort(
          title: (_) async => pageOf([oldest]),
          recent: (_) => recent.future,
        );
        nextPage = recent;
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseSortChanged(GameSort.newest));
        await pumpEventQueue();
        bloc.add(const GameBrowseSortChanged(GameSort.title));
        await pumpEventQueue();
        nextPage.complete(pageOf([newest]));
      },
      skip: 2,
      expect: () => [
        const GameBrowseLoading(sort: GameSort.newest),
        const GameBrowseLoading(),
        GameBrowseReady(games: [oldest]),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'more keeps the sort',
      setUp: () => remote.onFetchPage = (page, _) async => page == 1
          ? pageOf([newest, middle], hasMore: true)
          : pageOf([oldest], page: 2),
      build: () => build(sort: GameSort.newest),
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
      },
      skip: 2,
      expect: () => [
        GameBrowseReady(
          games: [newest, middle],
          hasMore: true,
          loadingMore: true,
          sort: GameSort.newest,
        ),
        GameBrowseReady(games: [newest, middle, oldest], sort: GameSort.newest),
      ],
      verify: (_) => expect(remote.calls, [
        'fetchPage(1, 2, newest)',
        'fetchPage(2, 2, newest)',
      ]),
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a game a newest page repeats, after one was added at the top, is '
      'shown once',
      setUp: () => remote.onFetchPage = (page, _) async => page == 1
          ? pageOf([newest, middle], hasMore: true)
          : pageOf([middle, oldest], page: 2),
      build: () => build(sort: GameSort.newest),
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
      },
      skip: 3,
      expect: () => [
        GameBrowseReady(games: [newest, middle, oldest], sort: GameSort.newest),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a failed read falls back to the cache in the same order',
      setUp: () async {
        await cache.cacheGames([oldest, newest, middle]);
        remote.onFetchPage = (_, _) async => throw unreachable();
      },
      build: () => build(sort: GameSort.newest),
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
      },
      skip: 3,
      expect: () => [
        GameBrowseReady(
          games: [newest, middle, oldest],
          fromCache: true,
          sort: GameSort.newest,
        ),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a sort change that fails falls back to the cache in the new order',
      setUp: () async {
        await cache.cacheGames([oldest, newest, middle]);
        remote.onFetchPage = (page, _) async =>
            remote.calls.last.endsWith('newest)')
            ? throw unreachable()
            : pageOf([oldest, newest], hasMore: true);
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseSortChanged(GameSort.newest));
      },
      skip: 2,
      expect: () => [
        const GameBrowseLoading(sort: GameSort.newest),
        GameBrowseReady(
          games: [newest, middle],
          hasMore: true,
          fromCache: true,
          sort: GameSort.newest,
        ),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a retry reads in the sort the list is in',
      setUp: () => remote.onFetchPage = (_, _) async => throw unreachable(),
      build: () => build(sort: GameSort.newest),
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        remote.onFetchPage = (_, _) async => pageOf([newest]);
        bloc.add(const GameBrowseLoadRequested());
      },
      expect: () => [
        const GameBrowseLoading(sort: GameSort.newest),
        const GameBrowseFailed(sort: GameSort.newest),
        const GameBrowseLoading(sort: GameSort.newest),
        GameBrowseReady(games: [newest], sort: GameSort.newest),
      ],
      verify: (_) => expect(remote.calls, [
        'fetchPage(1, 2, newest)',
        'fetchPage(1, 2, newest)',
      ]),
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a refusal keeps the sort',
      setUp: () =>
          remote.onFetchPage = (_, _) async =>
              throw const GamesForbiddenException('403'),
      build: () => build(sort: GameSort.newest),
      act: (bloc) => bloc.add(const GameBrowseLoadRequested()),
      expect: () => [
        const GameBrowseLoading(sort: GameSort.newest),
        const GameBrowseDenied(sort: GameSort.newest),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'a next page asked for while the sort change loads is not read',
      setUp: () {
        final recent = hang();
        remote.onFetchPage = bySort(
          title: (_) async => pageOf([oldest, newest], hasMore: true),
          recent: (_) => recent.future,
        );
        nextPage = recent;
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        bloc.add(const GameBrowseSortChanged(GameSort.newest));
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
        await pumpEventQueue();
        nextPage.complete(pageOf([newest, middle], hasMore: true));
      },
      skip: 2,
      expect: () => [
        const GameBrowseLoading(sort: GameSort.newest),
        GameBrowseReady(
          games: [newest, middle],
          hasMore: true,
          sort: GameSort.newest,
        ),
      ],
      verify: (_) =>
          expect(remote.calls, ['fetchPage(1, 2)', 'fetchPage(1, 2, newest)']),
    );

    group('a read of the old sort that never answers', () {
      // The old read keeps holding the slot reads are dropped from, so
      // anything the new list asks for would be dropped behind it.

      blocTest<GameBrowseBloc, GameBrowseState>(
        'does not keep the new list from paging, when it was the first page',
        setUp: () {
          final title = hang();
          remote.onFetchPage = bySort(
            title: (_) => title.future,
            recent: (page) async => page == 1
                ? pageOf([newest, middle], hasMore: true)
                : pageOf([oldest], page: 2),
          );
        },
        build: build,
        act: (bloc) async {
          bloc.add(const GameBrowseLoadRequested());
          await pumpEventQueue();
          bloc.add(const GameBrowseSortChanged(GameSort.newest));
          await pumpEventQueue();
          bloc.add(const GameBrowseMoreRequested());
        },
        skip: 2,
        expect: () => [
          GameBrowseReady(
            games: [newest, middle],
            hasMore: true,
            sort: GameSort.newest,
          ),
          GameBrowseReady(
            games: [newest, middle],
            hasMore: true,
            loadingMore: true,
            sort: GameSort.newest,
          ),
          GameBrowseReady(
            games: [newest, middle, oldest],
            sort: GameSort.newest,
          ),
        ],
      );

      blocTest<GameBrowseBloc, GameBrowseState>(
        'does not keep the new list from paging, when it was a next page',
        setUp: () {
          final title = hang();
          remote.onFetchPage = bySort(
            title: (page) => page == 1
                ? Future.value(pageOf([oldest, newest], hasMore: true))
                : title.future,
            recent: (page) async => page == 1
                ? pageOf([newest, middle], hasMore: true)
                : pageOf([oldest], page: 2),
          );
        },
        build: build,
        act: (bloc) async {
          bloc.add(const GameBrowseLoadRequested());
          await pumpEventQueue();
          bloc.add(const GameBrowseMoreRequested());
          await pumpEventQueue();
          bloc.add(const GameBrowseSortChanged(GameSort.newest));
          await pumpEventQueue();
          bloc.add(const GameBrowseMoreRequested());
        },
        skip: 5,
        expect: () => [
          GameBrowseReady(
            games: [newest, middle],
            hasMore: true,
            loadingMore: true,
            sort: GameSort.newest,
          ),
          GameBrowseReady(
            games: [newest, middle, oldest],
            sort: GameSort.newest,
          ),
        ],
      );

      blocTest<GameBrowseBloc, GameBrowseState>(
        'does not keep a retry of the new list from reading',
        setUp: () {
          final title = hang();
          remote.onFetchPage = bySort(
            title: (_) => title.future,
            recent: (_) async => throw unreachable(),
          );
        },
        build: () => build(withCache: false),
        act: (bloc) async {
          bloc.add(const GameBrowseLoadRequested());
          await pumpEventQueue();
          bloc.add(const GameBrowseSortChanged(GameSort.newest));
          await pumpEventQueue();
          remote.onFetchPage = (_, _) async => pageOf([newest]);
          bloc.add(const GameBrowseLoadRequested());
        },
        skip: 2,
        expect: () => [
          const GameBrowseFailed(sort: GameSort.newest),
          const GameBrowseLoading(sort: GameSort.newest),
          GameBrowseReady(games: [newest], sort: GameSort.newest),
        ],
      );
    });
  });

  group('a game found gone', () {
    late StreamController<String> gone;

    setUp(() => gone = StreamController<String>.broadcast());
    tearDown(() => gone.close());

    blocTest<GameBrowseBloc, GameBrowseState>(
      "is heard of wherever it was found, and the cache's next page starts "
      'where it should',
      setUp: () async {
        await cache.cacheGames([azul, brass, catan]);
        remote.onFetchPage = (_, _) async => throw unreachable();
      },
      build: () => build(gone: gone.stream),
      act: (bloc) async {
        bloc.add(const GameBrowseLoadRequested());
        await pumpEventQueue();
        // A detail opened from a search over this list.
        await cache.forgetGame('g_azul');
        gone.add('g_azul');
        await pumpEventQueue();
        bloc.add(const GameBrowseMoreRequested());
      },
      skip: 2,
      expect: () => [
        GameBrowseReady(games: [brass], hasMore: true, fromCache: true),
        GameBrowseReady(
          games: [brass],
          hasMore: true,
          fromCache: true,
          loadingMore: true,
        ),
        GameBrowseReady(games: [brass, catan], fromCache: true),
      ],
    );

    blocTest<GameBrowseBloc, GameBrowseState>(
      'stops being heard of once the list is closed',
      build: () => build(gone: gone.stream),
      verify: (_) => expect(gone.hasListener, isFalse),
    );

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
      'stays down when a page on its way repeats it, and is not cached again',
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
        // The detail forgets the game, then the list hears it is gone.
        await cache.forgetGame('g_azul');
        bloc.add(const GameBrowseGameGone('g_azul'));
        await pumpEventQueue();
        // A game added mid-browse pushed Azul onto the next page.
        nextPage.complete(pageOf([azul, catan], page: 2));
      },
      skip: 3,
      expect: () => [
        GameBrowseReady(games: [brass], hasMore: true, loadingMore: true),
        GameBrowseReady(games: [brass, catan]),
      ],
      verify: (_) async {
        expect(await cache.getGames(['g_azul']), isEmpty);
      },
    );

    test('stays forgotten when a list closed earlier is answered after '
        'it', () async {
      final older = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (_, _) => older.future;
      final closed = build()..add(const GameBrowseLoadRequested());
      await pumpEventQueue();
      await closed.close();

      // A detail opened since forgets the game.
      await cache.cacheGames([azul]);
      await cache.forgetGame('g_azul');

      older.complete(pageOf([azul, brass]));
      await pumpEventQueue();

      expect(await cache.getGames(['g_azul', 'g_brass']), isEmpty);
    });

    test("stays forgotten when a closed list's next page is answered after "
        'it', () async {
      final next = Completer<PaginatedResult<Game>>();
      remote.onFetchPage = (page, _) async =>
          page == 1 ? pageOf([brass], hasMore: true) : next.future;
      final closed = build()..add(const GameBrowseLoadRequested());
      await pumpEventQueue();
      closed.add(const GameBrowseMoreRequested());
      await pumpEventQueue();
      await closed.close();

      await cache.cacheGames([azul]);
      await cache.forgetGame('g_azul');

      next.complete(pageOf([azul, catan], page: 2));
      await pumpEventQueue();

      expect(await cache.getGames(['g_azul', 'g_catan']), isEmpty);
    });

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
