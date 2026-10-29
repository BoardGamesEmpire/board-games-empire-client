import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/catalog_app.dart';
import '../support/fake_games_remote.dart';

/// A cache that cannot forget, as a session ending mid-refusal would leave it.
class _FailingForgetCache extends FakeGamesCache {
  @override
  Future<void> forgetCatalog() async => throw StateError('disposed');
}

const _expansions = GameSearchFilter(contentTypes: {ContentType.expansion});

void main() {
  late FakeGamesRemote remote;

  setUp(() => remote = FakeGamesRemote());

  /// The DataGateways' names, for a test to answer by hand.
  late Completer<Map<String, String>> lateNames;

  /// A real games cache, for a test that seeds it once the bloc is built.
  late GameRepositoryImpl lateCache;

  /// A bloc that searches as soon as typing stops, so a test need not wait
  /// out the real debounce.
  GameSearchBloc build({
    GameRepository? cache,
    Future<Map<String, String>> Function()? sourceNames,
    Stream<String>? gone,
  }) => GameSearchBloc(
    remote: remote,
    cache: cache,
    sourceNames: sourceNames,
    gone: gone,
    debounce: Duration.zero,
  );

  /// Lets the debounce timer fire and the search answer.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 1));

  group('the query', () {
    blocTest<GameSearchBloc, GameSearchState>(
      'a burst of typing searches once, for the last text',
      setUp: () => remote.onSearch = (_, _) async => const GameSearchResults(),
      build: () => GameSearchBloc(
        remote: remote,
        debounce: const Duration(milliseconds: 20),
      ),
      act: (bloc) async {
        bloc
          ..add(const GameSearchQueryChanged('c'))
          ..add(const GameSearchQueryChanged('ca'))
          ..add(const GameSearchQueryChanged('cat'));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      },
      expect: () => [
        const GameSearchLoading(query: 'cat'),
        const GameSearchReady(query: 'cat'),
      ],
      verify: (_) => expect(remote.calls, ['search(cat)']),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'blank text is nothing to search for',
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('   '));
        await settle();
      },
      expect: () => [const GameSearchIdle()],
      verify: (_) => expect(remote.calls, isEmpty),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'clearing the text drops the answer still on its way',
      setUp: () {
        final slow = Completer<GameSearchResults>();
        remote.onSearch = (_, _) => slow.future;
        addTearDown(() => slow.complete(const GameSearchResults()));
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        bloc.add(const GameSearchQueryChanged(''));
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        const GameSearchIdle(),
      ],
    );
  });

  group('clearing the text', () {
    late Completer<GameSearchResults> slow;

    setUp(() {
      slow = Completer<GameSearchResults>();
      remote.onSearch = (_, _) => slow.future;
    });

    blocTest<GameSearchBloc, GameSearchState>(
      'goes back to idle at once, without waiting out the debounce, and the '
      'answer still on its way never shows',
      build: () => GameSearchBloc(
        remote: remote,
        debounce: const Duration(milliseconds: 100),
      ),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        bloc.add(const GameSearchQueryChanged(''));
        await pumpEventQueue();
        slow.complete(GameSearchResults(local: [hit('g_catan')]));
        await pumpEventQueue();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        const GameSearchIdle(),
      ],
    );
  });

  blocTest<GameSearchBloc, GameSearchState>(
    'retyping the same text while it is being searched still answers',
    setUp: () {
      final first = Completer<GameSearchResults>();
      var calls = 0;
      remote.onSearch = (_, _) =>
          calls++ == 0 ? first.future : Future.value(const GameSearchResults());
      addTearDown(() {
        if (!first.isCompleted) first.complete(const GameSearchResults());
      });
    },
    build: build,
    act: (bloc) async {
      bloc.add(const GameSearchQueryChanged('catan'));
      await settle();
      // A trailing space: the same search, and it cancels the handler
      // waiting on the first.
      bloc.add(const GameSearchQueryChanged('catan '));
      await settle();
    },
    expect: () => [
      const GameSearchLoading(query: 'catan'),
      const GameSearchReady(query: 'catan'),
    ],
  );

  blocTest<GameSearchBloc, GameSearchState>(
    'retyping the text already answered searches nothing',
    setUp: () => remote.onSearch = (_, _) async => const GameSearchResults(),
    build: build,
    act: (bloc) async {
      bloc.add(const GameSearchQueryChanged('catan'));
      await settle();
      bloc.add(const GameSearchQueryChanged(' catan'));
      await settle();
    },
    verify: (_) => expect(remote.calls, ['search(catan)']),
  );

  group('the two sections', () {
    late Completer<Map<String, String>> names;

    final results = GameSearchResults(
      local: [hit('g_catan', gameId: 'g_catan')],
      byDataGateway: {
        'dg_bgg': [
          // The same game, found again by the DataGateway it came from.
          hit('13', gameId: 'g_catan'),
          hit('926', title: 'Seafarers'),
        ],
        'dg_igdb': [hit('c-1', gameId: 'g_elsewhere')],
      },
      failedDataGateways: const {'dg_broken'},
      rateLimitedDataGateways: const {'dg_steam'},
      unavailableDataGateways: const {'dg_down'},
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'lists this server first, then what DataGateways found that it does '
      'not already list',
      setUp: () => remote.onSearch = (_, _) async => results,
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      skip: 1,
      expect: () => [
        isA<GameSearchReady>()
            .having((s) => s.onServer, 'onServer', [
              hit('g_catan', gameId: 'g_catan'),
            ])
            .having((s) => s.fromSources, 'fromSources', [
              GameSearchSourceHit(
                source: const GameSearchSource(id: 'dg_bgg'),
                hit: hit('926', title: 'Seafarers'),
              ),
              GameSearchSourceHit(
                source: const GameSearchSource(id: 'dg_igdb'),
                hit: hit('c-1', gameId: 'g_elsewhere'),
              ),
            ]),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'names every DataGateway that did not answer, however it failed',
      setUp: () => remote.onSearch = (_, _) async => results,
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      skip: 1,
      expect: () => [
        isA<GameSearchReady>().having(
          (s) => s.missingSources,
          'missingSources',
          const [
            GameSearchSource(id: 'dg_broken'),
            GameSearchSource(id: 'dg_steam'),
            GameSearchSource(id: 'dg_down'),
          ],
        ),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'names each DataGateway once its names arrive',
      setUp: () => remote.onSearch = (_, _) async => GameSearchResults(
        byDataGateway: {
          'dg_bgg': [hit('926')],
        },
        unavailableDataGateways: const {'dg_down'},
      ),
      build: () => build(sourceNames: () async => {'dg_bgg': 'BoardGameGeek'}),
      act: (bloc) async {
        await settle();
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      skip: 1,
      expect: () => [
        GameSearchReady(
          query: 'catan',
          fromSources: [
            GameSearchSourceHit(
              source: const GameSearchSource(
                id: 'dg_bgg',
                name: 'BoardGameGeek',
              ),
              hit: hit('926'),
            ),
          ],
          // A DataGateway the list did not name stays unnamed.
          missingSources: const [GameSearchSource(id: 'dg_down')],
        ),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'names the DataGateways the filter skipped, apart from those that did '
      'not answer',
      setUp: () => remote.onSearch = (_, _) async => const GameSearchResults(
        unfilterableDataGateways: {'dg_bgg'},
        unavailableDataGateways: {'dg_down'},
      ),
      build: () => build(sourceNames: () async => {'dg_bgg': 'BoardGameGeek'}),
      act: (bloc) async {
        await settle();
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      skip: 1,
      expect: () => [
        isA<GameSearchReady>()
            .having((s) => s.unfilterableSources, 'unfilterableSources', [
              const GameSearchSource(id: 'dg_bgg', name: 'BoardGameGeek'),
            ])
            .having((s) => s.missingSources, 'missingSources', [
              const GameSearchSource(id: 'dg_down'),
            ]),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'names results already on screen when the names arrive late',
      setUp: () => remote.onSearch = (_, _) async => GameSearchResults(
        byDataGateway: {
          'dg_bgg': [hit('926')],
        },
      ),
      build: () {
        names = Completer<Map<String, String>>();
        addTearDown(() {
          if (!names.isCompleted) names.complete({});
        });
        return build(sourceNames: () => names.future);
      },
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        // The names arrive after the results have.
        names.complete({'dg_bgg': 'BoardGameGeek'});
        await settle();
      },
      skip: 1,
      expect: () => [
        isA<GameSearchReady>().having(
          (s) => s.fromSources.single.source.name,
          'name',
          isNull,
        ),
        isA<GameSearchReady>().having(
          (s) => s.fromSources.single.source.name,
          'name',
          'BoardGameGeek',
        ),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a failed read of the names leaves every DataGateway unnamed',
      setUp: () => remote.onSearch = (_, _) async => GameSearchResults(
        byDataGateway: {
          'dg_bgg': [hit('926')],
        },
      ),
      build: () => build(sourceNames: () async => throw StateError('403')),
      act: (bloc) async {
        await settle();
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      skip: 1,
      expect: () => [
        isA<GameSearchReady>().having(
          (s) => s.fromSources.single.source.name,
          'name',
          isNull,
        ),
      ],
    );
  });

  group('the filter', () {
    blocTest<GameSearchBloc, GameSearchState>(
      'searches the current text again, narrowed',
      setUp: () => remote.onSearch = (_, _) async => const GameSearchResults(),
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        bloc.add(const GameSearchFilterChanged(_expansions));
        await settle();
      },
      skip: 2,
      expect: () => [
        const GameSearchLoading(query: 'catan', filter: _expansions),
        const GameSearchReady(query: 'catan', filter: _expansions),
      ],
      verify: (_) =>
          expect(remote.calls, ['search(catan)', 'search(catan [expansion])']),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'sends platform types too',
      setUp: () => remote.onSearch = (_, _) async => const GameSearchResults(),
      build: build,
      act: (bloc) async {
        bloc.add(
          const GameSearchFilterChanged(
            GameSearchFilter(platformTypes: {PlatformType.tabletop}),
          ),
        );
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      verify: (_) => expect(remote.calls, ['search(catan {tabletop})']),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'with nothing typed, is only remembered',
      build: build,
      act: (bloc) => bloc.add(const GameSearchFilterChanged(_expansions)),
      expect: () => [const GameSearchIdle(filter: _expansions)],
      verify: (_) => expect(remote.calls, isEmpty),
    );

    late Completer<GameSearchResults> unfiltered;

    blocTest<GameSearchBloc, GameSearchState>(
      'an older answer that lands last does not replace the newer one',
      setUp: () {
        unfiltered = Completer<GameSearchResults>();
        remote.onSearch = (_, filter) => filter.contentTypes.isEmpty
            ? unfiltered.future
            : Future.value(GameSearchResults(local: [hit('newer')]));
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        bloc.add(const GameSearchFilterChanged(_expansions));
        await settle();
        // Answers after the filtered search has.
        unfiltered.complete(GameSearchResults(local: [hit('older')]));
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        const GameSearchLoading(query: 'catan', filter: _expansions),
        GameSearchReady(
          query: 'catan',
          onServer: [hit('newer')],
          filter: _expansions,
        ),
      ],
    );
  });

  blocTest<GameSearchBloc, GameSearchState>(
    'a refusal says the user may not search, rather than searching the '
    'cache',
    setUp: () =>
        remote.onSearch = (_, _) async =>
            throw const GamesForbiddenException('403'),
    build: () {
      final db = inMemoryServerDatabase();
      addTearDown(db.close);
      return build(cache: GameRepositoryImpl(db, userId: 'user-a'));
    },
    act: (bloc) async {
      bloc.add(const GameSearchFilterChanged(_expansions));
      bloc.add(const GameSearchQueryChanged('catan'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    },
    skip: 2,
    expect: () => [const GameSearchDenied(query: 'catan', filter: _expansions)],
    verify: (_) => expect(remote.calls, ['search(catan [expansion])']),
  );

  group('a refusal', () {
    const refused = GamesForbiddenException('403');
    late ServerDatabase db;
    late GameRepositoryImpl cache;
    final catan = game('g_catan', title: 'Catan');

    setUp(() async {
      db = inMemoryServerDatabase();
      cache = GameRepositoryImpl(db, userId: 'user-a');
      await cache.cacheGame(catan);
    });
    tearDown(() => db.close());

    /// What a search over [cache] shows when the server can't be reached.
    Future<GameSearchState> searchOffline() async {
      remote.onSearch = (_, _) async => throw unreachable();
      final search = build(cache: cache);
      addTearDown(search.close);
      search.add(const GameSearchQueryChanged('catan'));
      await settle();
      return search.state;
    }

    blocTest<GameSearchBloc, GameSearchState>(
      'forgets the catalog, so a later failed search finds nothing cached',
      setUp: () => remote.onSearch = (_, _) async => throw refused,
      build: () => build(cache: cache),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        remote.onSearch = (_, _) async => throw unreachable();
        bloc.add(const GameSearchQueryChanged('cata'));
        await settle();
      },
      skip: 2,
      expect: () => [
        const GameSearchLoading(query: 'cata'),
        const GameSearchReady(query: 'cata', fromCache: true),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'still says the user may not search when forgetting fails',
      setUp: () => remote.onSearch = (_, _) async => throw refused,
      build: () => build(cache: _FailingForgetCache()),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        const GameSearchDenied(query: 'catan'),
      ],
    );

    test('in search leaves a new search nothing cached', () async {
      remote.onSearch = (_, _) async => throw refused;
      final first = build(cache: cache)
        ..add(const GameSearchQueryChanged('catan'));
      await first.stream.firstWhere((s) => s is GameSearchDenied);
      await first.close();

      expect(
        await searchOffline(),
        const GameSearchReady(query: 'catan', fromCache: true),
      );
    });

    test('in search leaves browse nothing cached', () async {
      remote.onSearch = (_, _) async => throw refused;
      final search = build(cache: cache)
        ..add(const GameSearchQueryChanged('catan'));
      await search.stream.firstWhere((s) => s is GameSearchDenied);
      await search.close();

      remote.onFetchPage = (_, _) async => throw unreachable();
      final browse = GameBrowseBloc(remote: remote, cache: cache, pageSize: 2);
      addTearDown(browse.close);
      final states = <GameBrowseState>[];
      final sub = browse.stream.listen(states.add);
      addTearDown(sub.cancel);
      browse.add(const GameBrowseLoadRequested());
      await pumpEventQueue();

      expect(states, [const GameBrowseLoading(), const GameBrowseFailed()]);
    });

    test('in browse leaves search nothing cached', () async {
      remote.onFetchPage = (_, _) async => throw refused;
      final browse = GameBrowseBloc(remote: remote, cache: cache, pageSize: 2)
        ..add(const GameBrowseLoadRequested());
      await browse.stream.firstWhere((s) => s is GameBrowseDenied);
      await browse.close();

      expect(
        await searchOffline(),
        const GameSearchReady(query: 'catan', fromCache: true),
      );
    });
  });

  group('a game found gone', () {
    final results = GameSearchResults(
      local: [hit('g_catan', gameId: 'g_catan')],
      byDataGateway: {
        'dg_bgg': [hit('926')],
        'dg_igdb': [hit('c-1', gameId: 'g_elsewhere')],
      },
    );
    late StreamController<String> gone;

    setUp(() => gone = StreamController<String>.broadcast());
    tearDown(() => gone.close());

    blocTest<GameSearchBloc, GameSearchState>(
      'is heard of wherever it was found',
      setUp: () => remote.onSearch = (_, _) async => results,
      build: () => build(gone: gone.stream),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        gone.add('g_elsewhere');
      },
      skip: 2,
      expect: () => [
        GameSearchReady(
          query: 'catan',
          onServer: [hit('g_catan', gameId: 'g_catan')],
          fromSources: [
            GameSearchSourceHit(
              source: const GameSearchSource(id: 'dg_bgg'),
              hit: hit('926'),
            ),
          ],
        ),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'stops being heard of once the search is closed',
      build: () => build(gone: gone.stream),
      verify: (_) => expect(gone.hasListener, isFalse),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'is taken down from either section, and the rest stays',
      setUp: () => remote.onSearch = (_, _) async => results,
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        bloc
          ..add(const GameSearchGameGone('g_catan'))
          ..add(const GameSearchGameGone('g_elsewhere'));
      },
      skip: 2,
      expect: () => [
        GameSearchReady(
          query: 'catan',
          fromSources: [
            GameSearchSourceHit(
              source: const GameSearchSource(id: 'dg_bgg'),
              hit: hit('926'),
            ),
            GameSearchSourceHit(
              source: const GameSearchSource(id: 'dg_igdb'),
              hit: hit('c-1', gameId: 'g_elsewhere'),
            ),
          ],
        ),
        GameSearchReady(
          query: 'catan',
          fromSources: [
            GameSearchSourceHit(
              source: const GameSearchSource(id: 'dg_bgg'),
              hit: hit('926'),
            ),
          ],
        ),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'stays down when the DataGateways\' names arrive after it',
      setUp: () => remote.onSearch = (_, _) async => results,
      build: () {
        final names = Completer<Map<String, String>>();
        addTearDown(() {
          if (!names.isCompleted) names.complete({});
        });
        lateNames = names;
        return build(sourceNames: () => names.future);
      },
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        bloc.add(const GameSearchGameGone('g_catan'));
        await settle();
        lateNames.complete({'dg_bgg': 'BoardGameGeek'});
        await settle();
      },
      skip: 3,
      expect: () => [
        isA<GameSearchReady>()
            .having((s) => s.onServer, 'onServer', isEmpty)
            .having(
              (s) => s.fromSources.map((r) => r.source.name),
              'names',
              contains('BoardGameGeek'),
            ),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'is taken down from what this device found, too',
      setUp: () => remote.onSearch = (_, _) async => throw unreachable(),
      build: () {
        final db = inMemoryServerDatabase();
        addTearDown(db.close);
        final cache = GameRepositoryImpl(db, userId: 'user-a');
        lateCache = cache;
        return build(cache: cache);
      },
      act: (bloc) async {
        await lateCache.cacheGames([
          game('g_catan', title: 'Catan'),
          game('g_seafarers', title: 'Catan: Seafarers'),
        ]);
        bloc.add(const GameSearchQueryChanged('catan'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
        bloc.add(const GameSearchGameGone('g_catan'));
      },
      skip: 2,
      expect: () => [
        isA<GameSearchReady>()
            .having((s) => s.fromCache, 'fromCache', isTrue)
            .having((s) => s.onServer.map((h) => h.gameId), 'gameIds', [
              'g_seafarers',
            ]),
      ],
    );
  });

  group('when the server cannot be reached', () {
    late ServerDatabase db;
    late GameRepositoryImpl cache;

    setUp(() {
      db = inMemoryServerDatabase();
      cache = GameRepositoryImpl(db, userId: 'user-a');
      remote.onSearch = (_, _) async => throw unreachable();
    });
    tearDown(() => db.close());

    blocTest<GameSearchBloc, GameSearchState>(
      'searches the games cached on this device instead, narrowed by the '
      'filter',
      setUp: () => cache.cacheGames([
        game('g_catan', title: 'Catan'),
        game(
          'g_seafarers',
          title: 'Catan: Seafarers',
          contentType: ContentType.expansion,
        ),
        game('g_azul', title: 'Azul'),
      ]),
      build: () => build(cache: cache),
      act: (bloc) async {
        bloc.add(const GameSearchFilterChanged(_expansions));
        bloc.add(const GameSearchQueryChanged('catan'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      skip: 2,
      expect: () => [
        GameSearchReady(
          query: 'catan',
          fromCache: true,
          filter: _expansions,
          onServer: const [
            GameSearchHit(
              externalId: 'g_seafarers',
              title: 'Catan: Seafarers',
              contentType: ContentType.expansion,
              gameId: 'g_seafarers',
            ),
          ],
        ),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'finds a cached match of the filter past a page of other matches',
      setUp: () => cache.cacheGames([
        for (var i = 0; i < GamesRemoteDataSource.searchPageSize; i++)
          game('g_catan_$i', title: 'Catan ${i.toString().padLeft(2, '0')}'),
        game(
          'g_seafarers',
          title: 'Catan: Seafarers',
          contentType: ContentType.expansion,
        ),
      ]),
      build: () => build(cache: cache),
      act: (bloc) async {
        bloc.add(const GameSearchFilterChanged(_expansions));
        bloc.add(const GameSearchQueryChanged('catan'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      skip: 2,
      expect: () => [
        GameSearchReady(
          query: 'catan',
          fromCache: true,
          filter: _expansions,
          onServer: const [
            GameSearchHit(
              externalId: 'g_seafarers',
              title: 'Catan: Seafarers',
              contentType: ContentType.expansion,
              gameId: 'g_seafarers',
            ),
          ],
        ),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'finds nothing cached when narrowed by platform type, which the cache '
      'does not hold',
      setUp: () => cache.cacheGames([game('g_catan', title: 'Catan')]),
      build: () => build(cache: cache),
      act: (bloc) async {
        bloc.add(
          const GameSearchFilterChanged(
            GameSearchFilter(platformTypes: {PlatformType.tabletop}),
          ),
        );
        bloc.add(const GameSearchQueryChanged('catan'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      skip: 2,
      expect: () => [
        const GameSearchReady(
          query: 'catan',
          fromCache: true,
          filter: GameSearchFilter(platformTypes: {PlatformType.tabletop}),
        ),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'fails when there is no cache to read',
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        const GameSearchFailed(query: 'catan'),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a retry asks the server again',
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        remote.onSearch = (_, _) async => const GameSearchResults();
        bloc.add(const GameSearchRetryRequested());
        await settle();
      },
      skip: 2,
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        const GameSearchReady(query: 'catan'),
      ],
    );
  });
}
