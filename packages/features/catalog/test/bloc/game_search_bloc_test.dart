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
import 'package:observability/observability.dart';

import '../support/catalog_app.dart';
import '../support/fake_game_search_channel.dart';
import '../support/fake_games_remote.dart';

/// A cache that cannot forget, as a session ending mid-refusal would leave it.
class _FailingForgetCache extends FakeGamesCache {
  @override
  Future<void> forgetCatalog() async => throw StateError('disposed');
}

/// A cache that cannot be searched, as a corrupt database would leave it.
class _FailingSearchCache extends FakeGamesCache {
  @override
  Future<List<Game>> searchGames(
    String query, {
    int limit = 20,
    GameSearchFilter filter = const GameSearchFilter(),
  }) async => throw StateError('corrupt');
}

/// A cache that counts how often it is told to forget the catalog.
class _CountingForgetCache extends FakeGamesCache {
  int forgotten = 0;

  @override
  Future<void> forgetCatalog() async => forgotten++;
}

/// A logger that keeps the errors it is warned of.
class _WarnedLogger extends BgeLogger {
  _WarnedLogger() : super('test.catalog.search');

  final List<Object?> warned = [];

  @override
  void warn(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, dynamic>? context,
  }) => warned.add(error);
}

const _expansions = GameSearchFilter(contentTypes: {ContentType.expansion});

void main() {
  late FakeGamesRemote remote;

  setUp(() => remote = FakeGamesRemote());

  /// The DataGateways' names, for a test to answer by hand.
  late Completer<Map<String, String>> lateNames;

  /// A real games cache, for a test that seeds it once the bloc is built.
  late GameRepositoryImpl lateCache;

  late _CountingForgetCache counting;
  Completer<GameSearchResults>? retryOf;

  /// The first ask of a search that a newer one supersedes, answered by hand.
  late Completer<GameSearchResults> superseded;

  /// A bloc that searches as soon as typing stops, so a test need not wait
  /// out the real debounce.
  GameSearchBloc build({
    GameRepository? cache,
    GameSearchChannel? stream,
    Future<Map<String, String>> Function()? sourceNames,
    Stream<String>? gone,
    DataGatewaySearchReach? reach,
    BgeLogger? logger,
  }) => GameSearchBloc(
    remote: remote,
    cache: cache,
    stream: stream,
    sourceNames: sourceNames,
    gone: gone,
    reach: reach,
    logger: logger,
    debounce: Duration.zero,
  );

  /// Lets the debounce timer fire and the search answer. A real-time delay
  /// can fall due before the debounce timer is even created, a microtask
  /// later, when the test stalls between them (#737).
  Future<void> settle() => pumpEventQueue();

  group('the query', () {
    blocTest<GameSearchBloc, GameSearchState>(
      'a burst of typing searches once, for the last text',
      setUp: () =>
          remote.onSearch = (_, _, _) async => const GameSearchResults(),
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
        remote.onSearch = (_, _, _) => slow.future;
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
      remote.onSearch = (_, _, _) => slow.future;
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
    'retyping the same text while it is being searched still answers, from '
    'the same search',
    build: build,
    act: (bloc) async {
      final first = Completer<GameSearchResults>();
      remote.onSearch = (_, _, _) => first.future;
      bloc.add(const GameSearchQueryChanged('catan'));
      await settle();
      // A trailing space: the same search. It cancels the handler waiting on
      // the first, and its own handler waits in its place.
      bloc.add(const GameSearchQueryChanged('catan '));
      await settle();
      first.complete(GameSearchResults(local: [hit('g_catan')]));
      await settle();
    },
    expect: () => [
      const GameSearchLoading(query: 'catan'),
      GameSearchReady(query: 'catan', onServer: [hit('g_catan')]),
    ],
    verify: (_) => expect(remote.calls, ['search(catan)']),
  );

  blocTest<GameSearchBloc, GameSearchState>(
    'retyping the text already answered searches nothing',
    setUp: () => remote.onSearch = (_, _, _) async => const GameSearchResults(),
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
      setUp: () => remote.onSearch = (_, _, _) async => results,
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

    // The screen keys each row by its id, and a keyed list needs each key
    // once, but nothing under the bloc drops a result a source repeats
    // (#473).
    blocTest<GameSearchBloc, GameSearchState>(
      'lists a result its source sends twice once, where it first came',
      setUp: () => remote.onSearch = (_, _, _) async => GameSearchResults(
        local: [
          hit('g_catan', gameId: 'g_catan', title: 'Catan'),
          hit('g_azul', gameId: 'g_azul', title: 'Azul'),
          hit('g_catan', gameId: 'g_catan', title: 'Catan again'),
        ],
        byDataGateway: {
          'dg_bgg': [
            hit('926', title: 'Seafarers'),
            // Its first copy is the game this server lists, so neither copy
            // is a row: the first copy decides for the repeat.
            hit('13', gameId: 'g_catan'),
            hit('927', title: 'Cities'),
            hit('926', title: 'Seafarers again'),
            hit('13', title: 'Catan, unlinked'),
          ],
          // Another DataGateway's result with the same id is a row of its
          // own.
          'dg_igdb': [hit('926', title: 'Something else')],
        },
      ),
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      skip: 1,
      expect: () => [
        isA<GameSearchReady>()
            .having((s) => s.onServer, 'onServer', [
              hit('g_catan', gameId: 'g_catan', title: 'Catan'),
              hit('g_azul', gameId: 'g_azul', title: 'Azul'),
            ])
            .having((s) => s.fromSources, 'fromSources', [
              GameSearchSourceHit(
                source: const GameSearchSource(id: 'dg_bgg'),
                hit: hit('926', title: 'Seafarers'),
              ),
              GameSearchSourceHit(
                source: const GameSearchSource(id: 'dg_bgg'),
                hit: hit('927', title: 'Cities'),
              ),
              GameSearchSourceHit(
                source: const GameSearchSource(id: 'dg_igdb'),
                hit: hit('926', title: 'Something else'),
              ),
            ])
            .having((s) => s.resultCount, 'resultCount', 5),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'names every DataGateway that did not answer, however it failed',
      setUp: () => remote.onSearch = (_, _, _) async => results,
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
      setUp: () => remote.onSearch = (_, _, _) async => GameSearchResults(
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
      setUp: () => remote.onSearch = (_, _, _) async => const GameSearchResults(
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
      setUp: () => remote.onSearch = (_, _, _) async => GameSearchResults(
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
      setUp: () => remote.onSearch = (_, _, _) async => GameSearchResults(
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
      setUp: () =>
          remote.onSearch = (_, _, _) async => const GameSearchResults(),
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
      setUp: () =>
          remote.onSearch = (_, _, _) async => const GameSearchResults(),
      build: build,
      act: (bloc) async {
        bloc
          ..add(
            const GameSearchFilterChanged(
              GameSearchFilter(platformTypes: {PlatformType.tabletop}),
            ),
          )
          ..add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      verify: (_) => expect(remote.calls, ['search(catan {tabletop})']),
    );

    const keepUndated = GameSearchFilter(
      publishYear: GameSearchRange(includeUnknown: true),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a change that narrows nothing new is kept without searching again',
      setUp: () =>
          remote.onSearch = (_, _, _) async => const GameSearchResults(),
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        // Keeping undated games, with no year bound, narrows nothing.
        bloc.add(const GameSearchFilterChanged(keepUndated));
        await settle();
        // Nor does the same filter again.
        bloc.add(const GameSearchFilterChanged(keepUndated));
        await settle();
      },
      skip: 2,
      expect: () => [
        const GameSearchReady(query: 'catan', filter: keepUndated),
      ],
      verify: (_) => expect(remote.calls, ['search(catan)']),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a change that narrows nothing new keeps everything the answer showed',
      setUp: () => remote.onSearch = (_, _, _) async => GameSearchResults(
        local: [hit('catan')],
        failedDataGateways: const {'dg_down'},
        unfilterableDataGateways: const {'dg_bgg'},
      ),
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        bloc.add(const GameSearchFilterChanged(keepUndated));
        await settle();
      },
      skip: 2,
      expect: () => [
        GameSearchReady(
          query: 'catan',
          onServer: [hit('catan')],
          missingSources: const [GameSearchSource(id: 'dg_down')],
          unfilterableSources: const [GameSearchSource(id: 'dg_bgg')],
          filter: keepUndated,
        ),
      ],
    );

    group('a change that narrows nothing new, made while a search is out, is '
        'kept when that search', () {
      /// Types, keeps undated games while the search is out, then has it
      /// end in [error].
      Future<void> changeWhilePending(GameSearchBloc bloc, Object error) async {
        // Made inside the test's zone: an error can't cross into another.
        final pending = Completer<GameSearchResults>();
        remote.onSearch = (_, _, _) => pending.future;
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        bloc.add(const GameSearchFilterChanged(keepUndated));
        await settle();
        pending.completeError(error);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      blocTest<GameSearchBloc, GameSearchState>(
        'fails',
        build: build,
        act: (bloc) => changeWhilePending(bloc, unreachable()),
        skip: 2,
        expect: () => [
          const GameSearchFailed(query: 'catan', filter: keepUndated),
        ],
      );

      blocTest<GameSearchBloc, GameSearchState>(
        'is refused',
        build: build,
        act: (bloc) =>
            changeWhilePending(bloc, const GamesForbiddenException('403')),
        skip: 2,
        expect: () => [
          const GameSearchDenied(query: 'catan', filter: keepUndated),
        ],
      );

      blocTest<GameSearchBloc, GameSearchState>(
        'falls back to a cache that fails too',
        build: () => build(cache: _FailingSearchCache()),
        act: (bloc) => changeWhilePending(bloc, unreachable()),
        skip: 2,
        expect: () => [
          const GameSearchFailed(query: 'catan', filter: keepUndated),
        ],
      );
    });

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
        remote.onSearch = (_, filter, _) => filter.contentTypes.isEmpty
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
        remote.onSearch = (_, _, _) async =>
            throw const GamesForbiddenException('403'),
    build: () {
      final db = inMemoryServerDatabase();
      addTearDown(db.close);
      return build(cache: GameRepositoryImpl(db, userId: 'user-a'));
    },
    act: (bloc) async {
      bloc
        ..add(const GameSearchFilterChanged(_expansions))
        ..add(const GameSearchQueryChanged('catan'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    },
    skip: 2,
    expect: () => [const GameSearchDenied(query: 'catan', filter: _expansions)],
    verify: (_) => expect(remote.calls, [
      'search(catan [expansion])',
      'search(catan [expansion] -external)',
    ]),
  );

  group('when the DataGateways are refused', () {
    const refused = GamesForbiddenException('403', apiMessage: 'm');

    blocTest<GameSearchBloc, GameSearchState>(
      'a 403 asking the DataGateways retries without them and shows this '
      "server's results",
      setUp: () => remote.onSearch = (_, _, includeExternal) async =>
          includeExternal
          ? throw refused
          : GameSearchResults(local: [hit('catan')]),
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(
          query: 'catan',
          onServer: [hit('catan')],
          dataGatewaysRefused: true,
          refusalMessage: 'm',
        ),
      ],
      verify: (_) =>
          expect(remote.calls, ['search(catan)', 'search(catan -external)']),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'the next search in the session skips the DataGateways from the start',
      setUp: () =>
          remote.onSearch = (_, _, includeExternal) async =>
              includeExternal ? throw refused : const GameSearchResults(),
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        remote.calls.clear();
        bloc.add(const GameSearchQueryChanged('cata'));
        await settle();
      },
      skip: 2,
      expect: () => [
        const GameSearchLoading(query: 'cata'),
        const GameSearchReady(
          query: 'cata',
          dataGatewaysRefused: true,
          refusalMessage: 'm',
        ),
      ],
      verify: (_) => expect(remote.calls, ['search(cata -external)']),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a 403 on the retry too is the catalog refused',
      setUp: () => remote.onSearch = (_, _, _) async => throw refused,
      build: () {
        counting = _CountingForgetCache();
        return build(cache: counting);
      },
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        const GameSearchDenied(query: 'catan'),
      ],
      verify: (_) {
        expect(remote.calls, ['search(catan)', 'search(catan -external)']);
        expect(counting.forgotten, 1);
      },
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a signed-out reach never asks the DataGateways',
      setUp: () =>
          remote.onSearch = (_, _, _) async =>
              GameSearchResults(local: [hit('catan')]),
      build: () => build(reach: DataGatewaySearchReach.signedOut()),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(
          query: 'catan',
          onServer: [hit('catan')],
          dataGatewaysRefused: true,
        ),
      ],
      verify: (_) => expect(remote.calls, ['search(catan -external)']),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a 403 on a search that did not ask the DataGateways is not retried',
      setUp: () => remote.onSearch = (_, _, _) async => throw refused,
      build: () => build(reach: DataGatewaySearchReach.signedOut()),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        const GameSearchDenied(query: 'catan'),
      ],
      verify: (_) => expect(remote.calls, ['search(catan -external)']),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a retry that fails otherwise searches this device',
      setUp: () =>
          remote.onSearch = (_, _, includeExternal) async =>
              throw includeExternal ? refused : unreachable(),
      build: () =>
          build(cache: FakeGamesCache([game('g_catan', title: 'Catan')])),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        isA<GameSearchReady>()
            .having((s) => s.fromCache, 'fromCache', isTrue)
            .having((s) => s.dataGatewaysRefused, 'refused', isFalse)
            .having((s) => s.refusalMessage, 'message', isNull),
      ],
      verify: (_) =>
          expect(remote.calls, ['search(catan)', 'search(catan -external)']),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'names that arrive later keep the refusal on the answer',
      setUp: () =>
          remote.onSearch = (_, _, includeExternal) async => includeExternal
          ? throw refused
          : GameSearchResults(
              local: [hit('catan')],
              byDataGateway: {
                'dg_bgg': [hit('926')],
              },
            ),
      build: () {
        lateNames = Completer();
        return build(sourceNames: () => lateNames.future);
      },
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        lateNames.complete({'dg_bgg': 'BoardGameGeek'});
        await settle();
      },
      skip: 2,
      expect: () => [
        isA<GameSearchReady>()
            .having((s) => s.dataGatewaysRefused, 'refused', isTrue)
            .having((s) => s.refusalMessage, 'message', 'm')
            .having(
              (s) => s.fromSources.single.source.name,
              'name',
              'BoardGameGeek',
            ),
      ],
    );

    // No one waits for a search superseded before its 403 lands, but the
    // 403 may be the catalog's, and only the retry tells (#557).
    blocTest<GameSearchBloc, GameSearchState>(
      'a search superseded before its 403 lands still retries, and a 403 '
      'there too forgets the catalog',
      setUp: () {
        superseded = Completer();
        addTearDown(() {
          if (!superseded.isCompleted) {
            superseded.complete(const GameSearchResults());
          }
        });
        remote.onSearch = (query, _, includeExternal) {
          if (query != 'old') {
            return Future.value(GameSearchResults(local: [hit('newer')]));
          }
          return includeExternal ? superseded.future : Future.error(refused);
        };
      },
      build: () {
        counting = _CountingForgetCache();
        return build(cache: counting);
      },
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('old'));
        await settle();
        bloc.add(const GameSearchQueryChanged('new'));
        await settle();
        superseded.completeError(refused);
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'old'),
        const GameSearchLoading(query: 'new'),
        GameSearchReady(query: 'new', onServer: [hit('newer')]),
      ],
      verify: (_) {
        expect(remote.calls, [
          'search(old)',
          'search(new)',
          'search(old -external)',
        ]);
        expect(counting.forgotten, 1);
      },
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a search superseded before its 403 lands still learns the refusal, '
      'and shows nothing',
      setUp: () {
        superseded = Completer();
        addTearDown(() {
          if (!superseded.isCompleted) {
            superseded.complete(const GameSearchResults());
          }
        });
        remote.onSearch = (query, _, includeExternal) {
          if (query != 'old') {
            return Future.value(GameSearchResults(local: [hit('newer')]));
          }
          return includeExternal
              ? superseded.future
              : Future.value(GameSearchResults(local: [hit('older')]));
        };
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('old'));
        await settle();
        bloc.add(const GameSearchQueryChanged('new'));
        await settle();
        superseded.completeError(refused);
        await settle();
        remote.calls.clear();
        bloc.add(const GameSearchQueryChanged('next'));
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'old'),
        const GameSearchLoading(query: 'new'),
        GameSearchReady(query: 'new', onServer: [hit('newer')]),
        const GameSearchLoading(query: 'next'),
        GameSearchReady(
          query: 'next',
          onServer: [hit('newer')],
          dataGatewaysRefused: true,
          refusalMessage: 'm',
        ),
      ],
      verify: (_) => expect(remote.calls, ['search(next -external)']),
    );

    // A stale retry still learned the refusal, so the session remembers it,
    // but nothing it found is shown.
    blocTest<GameSearchBloc, GameSearchState>(
      'a stale 403 retry is dropped',
      setUp: () {
        final retry = Completer<GameSearchResults>();
        addTearDown(() {
          if (!retry.isCompleted) retry.complete(const GameSearchResults());
        });
        remote.onSearch = (query, _, includeExternal) {
          if (query == 'old') {
            return includeExternal
                ? Future.error(refused)
                : (retryOf = retry).future;
          }
          return Future.value(GameSearchResults(local: [hit('newer')]));
        };
      },
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('old'));
        await settle();
        bloc.add(const GameSearchQueryChanged('new'));
        await settle();
        retryOf!.complete(GameSearchResults(local: [hit('older')]));
        await settle();
        remote.calls.clear();
        bloc.add(const GameSearchQueryChanged('next'));
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'old'),
        const GameSearchLoading(query: 'new'),
        GameSearchReady(query: 'new', onServer: [hit('newer')]),
        const GameSearchLoading(query: 'next'),
        GameSearchReady(
          query: 'next',
          onServer: [hit('newer')],
          dataGatewaysRefused: true,
          refusalMessage: 'm',
        ),
      ],
      verify: (_) => expect(remote.calls, ['search(next -external)']),
    );
  });

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
      remote.onSearch = (_, _, _) async => throw unreachable();
      final search = build(cache: cache);
      addTearDown(search.close);
      search.add(const GameSearchQueryChanged('catan'));
      await settle();
      return search.state;
    }

    blocTest<GameSearchBloc, GameSearchState>(
      'forgets the catalog, so a later failed search finds nothing cached',
      setUp: () => remote.onSearch = (_, _, _) async => throw refused,
      build: () => build(cache: cache),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        remote.onSearch = (_, _, _) async => throw unreachable();
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
      setUp: () => remote.onSearch = (_, _, _) async => throw refused,
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
      remote.onSearch = (_, _, _) async => throw refused;
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
      remote.onSearch = (_, _, _) async => throw refused;
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
      setUp: () => remote.onSearch = (_, _, _) async => results,
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
      setUp: () => remote.onSearch = (_, _, _) async => results,
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
      "stays down when the DataGateways' names arrive after it",
      setUp: () => remote.onSearch = (_, _, _) async => results,
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
      setUp: () => remote.onSearch = (_, _, _) async => throw unreachable(),
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
      remote.onSearch = (_, _, _) async => throw unreachable();
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
        bloc
          ..add(const GameSearchFilterChanged(_expansions))
          ..add(const GameSearchQueryChanged('catan'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      skip: 2,
      expect: () => [
        const GameSearchReady(
          query: 'catan',
          fromCache: true,
          filter: _expansions,
          onServer: [
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
        bloc
          ..add(const GameSearchFilterChanged(_expansions))
          ..add(const GameSearchQueryChanged('catan'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
      skip: 2,
      expect: () => [
        const GameSearchReady(
          query: 'catan',
          fromCache: true,
          filter: _expansions,
          onServer: [
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
        bloc
          ..add(
            const GameSearchFilterChanged(
              GameSearchFilter(platformTypes: {PlatformType.tabletop}),
            ),
          )
          ..add(const GameSearchQueryChanged('catan'));
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
        remote.onSearch = (_, _, _) async => const GameSearchResults();
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

  group('as each source answers', () {
    late FakeGameSearchChannel channel;
    late DataGatewaySearchReach reach;

    setUp(() => channel = FakeGameSearchChannel());

    final onServer = [hit('g_catan', gameId: 'g_catan')];

    /// A DataGateway's row: [externalId], as [sourceId] found it.
    GameSearchSourceHit row(String sourceId, String externalId) =>
        GameSearchSourceHit(
          source: GameSearchSource(id: sourceId),
          hit: hit(externalId),
        );

    blocTest<GameSearchBloc, GameSearchState>(
      'answers stream in as they arrive, searching until done',
      build: () => build(stream: channel),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        final search = channel.searches.single;
        final local = GameSearchResults(local: onServer);
        search.answer(local, localDone: true);
        await settle();
        final twoSources = local.copyWith(
          byDataGateway: {
            'dg_bgg': [hit('926')],
            'dg_igdb': [hit('c-1')],
          },
        );
        search.answer(twoSources, localDone: true);
        await settle();
        // More from the first source, after the second's: its rows stay
        // together, in the order the sources first answered.
        search.answer(
          twoSources.copyWith(
            byDataGateway: {
              'dg_bgg': [hit('926'), hit('927')],
              'dg_igdb': [hit('c-1')],
            },
          ),
          localDone: true,
          done: true,
        );
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(
          query: 'catan',
          onServer: onServer,
          searching: true,
          streamed: true,
        ),
        GameSearchReady(
          query: 'catan',
          onServer: onServer,
          fromSources: [row('dg_bgg', '926'), row('dg_igdb', 'c-1')],
          searching: true,
          streamed: true,
        ),
        GameSearchReady(
          query: 'catan',
          onServer: onServer,
          fromSources: [
            row('dg_bgg', '926'),
            row('dg_bgg', '927'),
            row('dg_igdb', 'c-1'),
          ],
          streamed: true,
        ),
      ],
      verify: (_) {
        expect(channel.calls, ['search(catan)']);
        expect(remote.calls, isEmpty);
      },
    );

    // The screen says a streamed search's first results and its end from
    // its footer, and an answer that came whole from the count above the
    // results (#473), so it reads which this is from the answer itself.
    blocTest<GameSearchBloc, GameSearchState>(
      'says which answers came over the stream, search by search',
      setUp: () {
        remote.onSearch = (_, _, _) async => GameSearchResults(local: onServer);
        // The socket can't serve the second search, so REST does.
        channel.onListen = (search) {
          if (search.described == 'azul') {
            search.fail(const RealtimeUnavailableException('down'));
          }
        };
      },
      build: () => build(stream: channel),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        // This server's half and the end in one answer: streamed all the
        // same.
        channel.searches.single.answer(
          GameSearchResults(local: onServer),
          localDone: true,
          done: true,
        );
        await settle();
        bloc.add(const GameSearchQueryChanged('azul'));
        await settle();
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        channel.searches.last.answer(
          GameSearchResults(local: onServer),
          localDone: true,
        );
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(query: 'catan', onServer: onServer, streamed: true),
        const GameSearchLoading(query: 'azul'),
        // Over REST, in a session that has a channel: not streamed.
        GameSearchReady(query: 'azul', onServer: onServer),
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(
          query: 'catan',
          onServer: onServer,
          searching: true,
          streamed: true,
        ),
      ],
      verify: (_) {
        expect(channel.calls, [
          'search(catan)',
          'search(azul)',
          'search(catan)',
          // Still running as the bloc closes.
          'cancel(catan)',
        ]);
        expect(remote.calls, ['search(azul)']);
      },
    );

    blocTest<GameSearchBloc, GameSearchState>(
      "loading lasts until this server's half finishes",
      build: () => build(stream: channel),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        final search = channel.searches.single;
        final local = GameSearchResults(local: onServer);
        search.answer(local);
        await settle();
        final found = local.copyWith(
          byDataGateway: {
            'dg_bgg': [hit('926')],
          },
        );
        search.answer(found);
        await settle();
        search.answer(found, localDone: true);
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(
          query: 'catan',
          onServer: onServer,
          fromSources: [row('dg_bgg', '926')],
          searching: true,
          streamed: true,
        ),
      ],
    );

    // The server reports a game it imported again under the DataGateway it
    // came from (backend#662). Shown before the server's own half, its row
    // would go again when that half lists the game.
    blocTest<GameSearchBloc, GameSearchState>(
      "DataGateway rows wait for this server's half",
      build: () => build(stream: channel),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        final search = channel.searches.single;
        final early = GameSearchResults(
          byDataGateway: {
            'dg_bgg': [hit('13', gameId: 'g1')],
          },
        );
        search.answer(early);
        await settle();
        final both = early.copyWith(local: [hit('g1', gameId: 'g1')]);
        search.answer(both);
        await settle();
        search.answer(both, localDone: true);
        await settle();
        search.answer(both, localDone: true, done: true);
        await settle();
      },
      // No state ever lists the DataGateway's g1.
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(
          query: 'catan',
          onServer: [hit('g1', gameId: 'g1')],
          searching: true,
          streamed: true,
        ),
        GameSearchReady(
          query: 'catan',
          onServer: [hit('g1', gameId: 'g1')],
          streamed: true,
        ),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a cut-short answer ends not searching, marked cutShort',
      build: () => build(stream: channel),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        final local = GameSearchResults(local: onServer);
        channel.searches.single
          ..answer(local, localDone: true)
          ..answer(local, localDone: true, done: true, cutShort: true);
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(
          query: 'catan',
          onServer: onServer,
          searching: true,
          streamed: true,
        ),
        GameSearchReady(
          query: 'catan',
          onServer: onServer,
          cutShort: true,
          streamed: true,
        ),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a new query cancels the running stream before the next search starts',
      build: () => build(stream: channel),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('cat'));
        await settle();
        final older = channel.searches.single
          ..answer(GameSearchResults(local: [hit('older')]), localDone: true);
        await settle();
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        // The cancelled search's last answer reaches no one.
        older.answer(
          GameSearchResults(local: [hit('older'), hit('late')]),
          localDone: true,
          done: true,
        );
        await settle();
        channel.searches.last.answer(
          GameSearchResults(local: [hit('newer')]),
          localDone: true,
          done: true,
        );
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'cat'),
        GameSearchReady(
          query: 'cat',
          onServer: [hit('older')],
          searching: true,
          streamed: true,
        ),
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(
          query: 'catan',
          onServer: [hit('newer')],
          streamed: true,
        ),
      ],
      verify: (_) => expect(channel.calls, [
        'search(cat)',
        'cancel(cat)',
        'search(catan)',
      ]),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a filter change mid-stream cancels it',
      build: () => build(stream: channel),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        final unfiltered = channel.searches.single
          ..answer(GameSearchResults(local: [hit('older')]), localDone: true);
        await settle();
        bloc.add(const GameSearchFilterChanged(_expansions));
        await settle();
        unfiltered.answer(
          GameSearchResults(local: [hit('older'), hit('late')]),
          localDone: true,
          done: true,
        );
        await settle();
        channel.searches.last.answer(
          GameSearchResults(local: [hit('newer')]),
          localDone: true,
          done: true,
        );
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(
          query: 'catan',
          onServer: [hit('older')],
          searching: true,
          streamed: true,
        ),
        const GameSearchLoading(query: 'catan', filter: _expansions),
        GameSearchReady(
          query: 'catan',
          onServer: [hit('newer')],
          filter: _expansions,
          streamed: true,
        ),
      ],
      verify: (_) => expect(channel.calls, [
        'search(catan)',
        'cancel(catan)',
        'search(catan [expansion])',
      ]),
    );

    // Its handler was following the answers still arriving, and the change
    // cancelled it, as one waiting on a REST answer is.
    blocTest<GameSearchBloc, GameSearchState>(
      'retyping the same text while its answers arrive keeps them arriving',
      build: () => build(stream: channel),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        final search = channel.searches.single
          ..answer(GameSearchResults(local: onServer), localDone: true);
        await settle();
        // A trailing space, then another: each change cancels the handler
        // showing the search, and the next takes it over.
        bloc.add(const GameSearchQueryChanged('catan '));
        await settle();
        bloc.add(const GameSearchQueryChanged('catan  '));
        await settle();
        search.answer(
          GameSearchResults(
            local: onServer,
            byDataGateway: {
              'dg_bgg': [hit('926')],
            },
          ),
          localDone: true,
          done: true,
        );
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(
          query: 'catan',
          onServer: onServer,
          searching: true,
          streamed: true,
        ),
        GameSearchReady(
          query: 'catan',
          onServer: onServer,
          fromSources: [row('dg_bgg', '926')],
          streamed: true,
        ),
      ],
      verify: (_) => expect(channel.calls, ['search(catan)']),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'other text typed after a hand-over still starts its own search',
      build: () => build(stream: channel),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        channel.searches.single.answer(
          GameSearchResults(local: onServer),
          localDone: true,
        );
        await settle();
        bloc.add(const GameSearchQueryChanged('catan '));
        await settle();
        bloc.add(const GameSearchQueryChanged('azul'));
        await settle();
        channel.searches.last.answer(
          GameSearchResults(local: [hit('g_azul', gameId: 'g_azul')]),
          localDone: true,
          done: true,
        );
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(
          query: 'catan',
          onServer: onServer,
          searching: true,
          streamed: true,
        ),
        const GameSearchLoading(query: 'azul'),
        GameSearchReady(
          query: 'azul',
          onServer: [hit('g_azul', gameId: 'g_azul')],
          streamed: true,
        ),
      ],
      verify: (_) => expect(channel.calls, [
        'search(catan)',
        'cancel(catan)',
        'search(azul)',
      ]),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'names that arrive while answers do leave it searching',
      build: () {
        lateNames = Completer();
        return build(stream: channel, sourceNames: () => lateNames.future);
      },
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        channel.searches.single.answer(
          GameSearchResults(
            local: onServer,
            byDataGateway: {
              'dg_bgg': [hit('926')],
            },
          ),
          localDone: true,
        );
        await settle();
        lateNames.complete({'dg_bgg': 'BoardGameGeek'});
        await settle();
      },
      skip: 2,
      expect: () => [
        isA<GameSearchReady>()
            .having(
              (s) => s.fromSources.single.source.name,
              'name',
              'BoardGameGeek',
            )
            .having((s) => s.searching, 'searching', isTrue)
            .having((s) => s.streamed, 'streamed', isTrue),
      ],
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a failed socket searches over REST without waiting',
      setUp: () {
        remote.onSearch = (_, _, _) async => GameSearchResults(local: onServer);
        // A lease that has already failed to connect answers at once.
        channel.onListen = (search) =>
            search.fail(const RealtimeUnavailableException('down'));
      },
      build: () => build(stream: channel),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        // Turns of the event queue, which no timer outlasts.
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(query: 'catan', onServer: onServer),
      ],
      verify: (_) {
        expect(channel.calls, ['search(catan)']);
        expect(remote.calls, ['search(catan)']);
      },
    );

    blocTest<GameSearchBloc, GameSearchState>(
      "a socket lost after only a DataGateway's answer searches over REST",
      setUp: () =>
          remote.onSearch = (_, _, _) async =>
              GameSearchResults(local: onServer),
      build: () => build(stream: channel),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        // Not shown: it waits for this server's half, which never comes.
        channel.searches.single
          ..answer(
            GameSearchResults(
              byDataGateway: {
                'dg_bgg': [hit('926')],
              },
            ),
          )
          ..fail(const RealtimeUnavailableException('dropped'));
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(query: 'catan', onServer: onServer),
      ],
      verify: (_) => expect(remote.calls, ['search(catan)']),
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a 403 on the stream retries the stream without the DataGateways',
      setUp: () => channel.onListen = (search) {
        if (search.described == 'catan') {
          search.fail(const GamesForbiddenException('403', apiMessage: 'm'));
        }
      },
      build: () =>
          build(stream: channel, reach: reach = DataGatewaySearchReach()),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        channel.searches.last.answer(
          GameSearchResults(local: onServer),
          localDone: true,
          done: true,
        );
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(
          query: 'catan',
          onServer: onServer,
          dataGatewaysRefused: true,
          refusalMessage: 'm',
          streamed: true,
        ),
      ],
      verify: (_) {
        expect(channel.calls, ['search(catan)', 'search(catan -external)']);
        expect(remote.calls, isEmpty);
        // The session remembers it, as it does a refusal over REST.
        expect(reach.mayAsk, isFalse);
      },
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a 403 retry the socket cannot serve goes over REST',
      setUp: () {
        remote.onSearch = (_, _, _) async => GameSearchResults(local: onServer);
        channel.onListen = (search) => search.fail(
          search.described == 'catan'
              ? const GamesForbiddenException('403', apiMessage: 'm')
              : const RealtimeUnavailableException('down'),
        );
      },
      build: () => build(stream: channel),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(
          query: 'catan',
          onServer: onServer,
          dataGatewaysRefused: true,
          refusalMessage: 'm',
        ),
      ],
      verify: (_) {
        expect(channel.calls, ['search(catan)', 'search(catan -external)']);
        expect(remote.calls, ['search(catan -external)']);
      },
    );

    // A stream followed for the superseded search's retry would take the
    // newer search's place as the one the next search stops.
    blocTest<GameSearchBloc, GameSearchState>(
      "a superseded search's retry goes over REST, and the next search stops "
      "the newer search's stream",
      setUp: () {
        superseded = Completer();
        addTearDown(() {
          if (!superseded.isCompleted) {
            superseded.complete(const GameSearchResults());
          }
        });
        // The socket can't serve the first search, so REST does.
        channel.onListen = (search) {
          if (search.described == 'old') {
            search.fail(const RealtimeUnavailableException('down'));
          }
        };
        remote.onSearch = (_, _, includeExternal) => includeExternal
            ? superseded.future
            : Future.value(GameSearchResults(local: [hit('older')]));
      },
      build: () => build(stream: channel),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('old'));
        await settle();
        bloc.add(const GameSearchQueryChanged('new'));
        await settle();
        superseded.completeError(
          const GamesForbiddenException('403', apiMessage: 'm'),
        );
        await settle();
        bloc.add(const GameSearchQueryChanged('next'));
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'old'),
        const GameSearchLoading(query: 'new'),
        const GameSearchLoading(query: 'next'),
      ],
      verify: (_) {
        expect(remote.calls, ['search(old)', 'search(old -external)']);
        expect(channel.calls, [
          'search(old)',
          'search(new)',
          'cancel(new)',
          'search(next -external)',
          // Closing the bloc stops the last.
          'cancel(next -external)',
        ]);
      },
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'a stream failure after answers searches this device',
      build: () => build(
        stream: channel,
        cache: FakeGamesCache([game('g_catan', title: 'Catan')]),
      ),
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        final search = channel.searches.single
          ..answer(
            GameSearchResults(local: [hit('streamed')]),
            localDone: true,
          );
        await settle();
        search.fail(unreachable());
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(
          query: 'catan',
          onServer: [hit('streamed')],
          searching: true,
          streamed: true,
        ),
        // The device's answer comes whole: not streamed.
        isA<GameSearchReady>()
            .having((s) => s.fromCache, 'fromCache', isTrue)
            .having((s) => s.searching, 'searching', isFalse)
            .having((s) => s.streamed, 'streamed', isFalse)
            .having((s) => s.onServer.map((h) => h.gameId), 'gameIds', [
              'g_catan',
            ]),
      ],
      verify: (_) => expect(remote.calls, isEmpty),
    );

    test('close cancels the running search and closes the channel', () async {
      final bloc = build(stream: channel);
      final states = <GameSearchState>[];
      final heard = bloc.stream.listen(states.add);
      addTearDown(heard.cancel);
      bloc.add(const GameSearchQueryChanged('catan'));
      await settle();
      final search = channel.searches.single
        ..answer(GameSearchResults(local: onServer), localDone: true);
      await settle();

      await bloc.close();
      // Nothing reaches a closed bloc.
      search.answer(
        GameSearchResults(local: [...onServer, hit('late')]),
        localDone: true,
        done: true,
      );
      await settle();

      expect(channel.calls, ['search(catan)', 'cancel(catan)']);
      expect(search.cancelled, isTrue);
      expect(channel.closes, 1);
      expect(states, [
        const GameSearchLoading(query: 'catan'),
        GameSearchReady(
          query: 'catan',
          onServer: onServer,
          searching: true,
          streamed: true,
        ),
      ]);
    });

    test('a channel that fails to close still leaves the bloc closed, and '
        'is logged rather than thrown', () async {
      // The screen's provider doesn't await close, so a throw here would
      // reach the uncaught-error hook and show the user a crash prompt.
      final gone = StreamController<String>.broadcast();
      addTearDown(gone.close);
      final failure = StateError('the lease would not release');
      channel.closeError = failure;
      final logger = _WarnedLogger();
      final bloc = build(stream: channel, gone: gone.stream, logger: logger);

      await bloc.close();

      expect(channel.closes, 1);
      expect(bloc.isClosed, isTrue);
      expect(gone.hasListener, isFalse);
      expect(logger.warned, [same(failure)]);
    });

    test('a REST answer that lands as the bloc closes is not shown', () async {
      final pending = Completer<GameSearchResults>();
      remote.onSearch = (_, _, _) => pending.future;
      final bloc = build();
      final states = <GameSearchState>[];
      final heard = bloc.stream.listen(states.add);
      addTearDown(heard.cancel);
      bloc.add(const GameSearchQueryChanged('catan'));
      await settle();

      final closed = bloc.close();
      pending.complete(GameSearchResults(local: onServer));
      await closed;

      expect(states, [const GameSearchLoading(query: 'catan')]);
    });

    test(
      'a search that reaches the bloc as it closes starts nothing',
      () async {
        final bloc = build(stream: channel);
        final states = <GameSearchState>[];
        final heard = bloc.stream.listen(states.add);
        addTearDown(heard.cancel);
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
        channel.searches.single.answer(
          GameSearchResults(local: onServer),
          localDone: true,
          done: true,
        );
        await settle();

        // Added in the same turn as the close, so its handler still runs.
        bloc.add(const GameSearchFilterChanged(_expansions));
        await bloc.close();

        expect(channel.calls, ['search(catan)']);
        expect(states, [
          const GameSearchLoading(query: 'catan'),
          GameSearchReady(query: 'catan', onServer: onServer, streamed: true),
        ]);
      },
    );

    blocTest<GameSearchBloc, GameSearchState>(
      'with no channel, REST answers as one finished answer',
      setUp: () => remote.onSearch = (_, _, _) async => GameSearchResults(
        local: onServer,
        byDataGateway: {
          'dg_bgg': [hit('926')],
        },
      ),
      build: build,
      act: (bloc) async {
        bloc.add(const GameSearchQueryChanged('catan'));
        await settle();
      },
      expect: () => [
        const GameSearchLoading(query: 'catan'),
        isA<GameSearchReady>()
            .having((s) => s.resultCount, 'resultCount', 2)
            .having((s) => s.searching, 'searching', isFalse)
            .having((s) => s.cutShort, 'cutShort', isFalse)
            .having((s) => s.streamed, 'streamed', isFalse),
      ],
      verify: (_) => expect(remote.calls, ['search(catan)']),
    );
  });
}
