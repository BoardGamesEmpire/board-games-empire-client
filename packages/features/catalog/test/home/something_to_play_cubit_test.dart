import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_connectivity.dart';
import '../support/fake_game_pool.dart';
import '../support/fake_games_remote.dart';

void main() {
  late FakeGamesRemote remote;
  late FakeGamePool pool;
  late FakeOwnGames own;
  late FakeConnectivity connectivity;

  setUp(() {
    remote = FakeGamesRemote();
    pool = FakeGamePool();
    own = FakeOwnGames();
    connectivity = FakeConnectivity();
  });

  tearDown(() async {
    await connectivity.close();
    await own.close();
  });

  /// A cubit that is closed when the test ends.
  SomethingToPlayCubit cubit({
    HouseholdRemoteDataSource? pool,
    GameCollectionRepository? collection,
    Stream<List<Household>>? households,
    Stream<String>? gone,
  }) {
    final made = SomethingToPlayCubit(
      remote: remote,
      pool: pool,
      collection: collection,
      households: households,
      connectivity: connectivity,
      gone: gone,
      random: Random(1),
    );
    addTearDown(made.close);
    return made;
  }

  /// A cubit with the pool and the collection, whose collection first answers
  /// [items], and whose first draw has landed.
  Future<SomethingToPlayCubit> drawn({
    List<GameCollectionListItem> items = const [],
    Stream<List<Household>>? households,
    Stream<String>? gone,
  }) async {
    final made = cubit(
      pool: pool,
      collection: own,
      households: households,
      gone: gone,
    );
    await pumpEventQueue();
    own.emit(items);
    await pumpEventQueue();
    return made;
  }

  List<String> ids(SomethingToPlayCubit cubit) => [
    for (final game in (cubit.state as SomethingToPlayReady).games) game.id,
  ];

  int draw(SomethingToPlayCubit cubit) =>
      (cubit.state as SomethingToPlayReady).draw;

  Future<GamePoolSample> poolFails(int _) async => throw StateError('no pool');
  Future<List<GameSummary>> randomFails(int _) async => throw unreachable();
  Future<List<GameSummary>> randomGames(int _) async => [summary('r-1')];

  group('the draw', () {
    test('merges pool and own, one row per game, at most 10', () async {
      pool.onSample = (_) async =>
          poolOf([for (var n = 0; n < 10; n++) 'p-$n']);

      final made = await drawn(
        items: [for (var n = 0; n < 10; n++) ownItem('o-$n')],
      );

      final shown = ids(made);
      expect(pool.reads, [10]);
      expect(shown, hasLength(10));
      expect(shown.toSet(), hasLength(10));
      expect(shown.where((id) => id.startsWith('p-')), isNotEmpty);
      expect(shown.where((id) => id.startsWith('o-')), isNotEmpty);
      expect(remote.calls, isEmpty);
    });

    test('shuffles, so that the row is not pool first and own after', () async {
      pool.onSample = (_) async => poolOf(['p-0', 'p-1', 'p-2', 'p-3']);

      final made = await drawn(
        items: [ownItem('o-0'), ownItem('o-1'), ownItem('o-2')],
      );

      expect(
        ids(made),
        unorderedEquals(['p-0', 'p-1', 'p-2', 'p-3', 'o-0', 'o-1', 'o-2']),
      );
      expect(
        ids(made),
        isNot(['p-0', 'p-1', 'p-2', 'p-3', 'o-0', 'o-1', 'o-2']),
      );
    });

    test('an own game also in the pool appears once', () async {
      pool.onSample = (_) async => poolOf(['g-1', 'g-2']);

      final made = await drawn(items: [ownItem('g-2'), ownItem('g-3')]);

      expect(ids(made), unorderedEquals(['g-1', 'g-2', 'g-3']));
    });

    test('two entries of one game (two media) appear once', () async {
      final made = await drawn(
        items: [
          ownItem('g-1', entryId: 'physical'),
          ownItem('g-1', entryId: 'digital', medium: GameMedium.digital),
          ownItem('g-2'),
        ],
      );

      expect(ids(made), unorderedEquals(['g-1', 'g-2']));
    });

    test('an own game is shown from its list row', () async {
      final made = await drawn(
        items: [
          ownItem('g-1', title: 'Catan', subtitle: 'A', thumbnail: 'http://t'),
        ],
      );

      expect(
        (made.state as SomethingToPlayReady).games.single,
        const GameSummary(
          id: 'g-1',
          title: 'Catan',
          subtitle: 'A',
          thumbnail: 'http://t',
        ),
      );
    });

    test('no household: own games only, no random read', () async {
      // The server answers 200 with no games to a caller with no household.
      final made = await drawn(items: [ownItem('o-1')]);

      expect(pool.reads, [10]);
      expect(ids(made), ['o-1']);
      expect(remote.calls, isEmpty);
    });

    test('nothing from either: random games', () async {
      remote.onFetchRandom = randomGames;

      final made = await drawn();

      expect(remote.calls, ['fetchRandom(10)']);
      expect(ids(made), ['r-1']);
    });

    test(
      'a household with an empty pool and no collection: random games',
      () async {
        remote.onFetchRandom = randomGames;

        final made = cubit(pool: pool);
        await pumpEventQueue();

        expect(pool.reads, [10]);
        expect(remote.calls, ['fetchRandom(10)']);
        expect(ids(made), ['r-1']);
      },
    );

    test(
      'no pool and no collection: draws at once, from random games',
      () async {
        remote.onFetchRandom = randomGames;

        final made = cubit();
        await pumpEventQueue();

        expect(ids(made), ['r-1']);
      },
    );

    test('a failed pool read shows own games, no error', () async {
      pool.onSample = poolFails;

      final made = await drawn(items: [ownItem('o-1')]);

      expect(ids(made), ['o-1']);
      expect(remote.calls, isEmpty);
    });

    test('a failed pool read and nothing own: random games', () async {
      pool.onSample = poolFails;
      remote.onFetchRandom = randomGames;

      final made = await drawn();

      expect(ids(made), ['r-1']);
    });

    test('all three failing: Nothing', () async {
      pool.onSample = poolFails;
      remote.onFetchRandom = randomFails;

      final made = cubit(pool: pool, collection: own);
      await pumpEventQueue();
      own.fail();
      await pumpEventQueue();

      expect(made.state, const SomethingToPlayNothing());
    });

    test('the server having no games: Nothing', () async {
      remote.onFetchRandom = (_) async => const [];

      final made = await drawn();

      expect(made.state, const SomethingToPlayNothing());
    });

    test('offline: own games only, no requests', () async {
      connectivity.current = ConnectivityState.offline;

      final made = await drawn(items: [ownItem('o-1')]);

      expect(ids(made), ['o-1']);
      expect(pool.reads, isEmpty);
      expect(remote.calls, isEmpty);
    });

    test('offline and nothing own: Nothing', () async {
      connectivity.current = ConnectivityState.offline;

      final made = await drawn();

      expect(made.state, const SomethingToPlayNothing());
      expect(pool.reads, isEmpty);
      expect(remote.calls, isEmpty);
    });

    test('waits for the first collection answer before drawing', () async {
      remote.onFetchRandom = randomGames;

      final made = cubit(pool: pool, collection: own);
      await pumpEventQueue();

      expect(made.state, const SomethingToPlayLoading());
      expect(pool.reads, isEmpty);
      expect(remote.calls, isEmpty, reason: 'no flash of random games');

      own.emit([ownItem('o-1')]);
      await pumpEventQueue();

      expect(ids(made), ['o-1']);
      expect(remote.calls, isEmpty);
    });

    test('a failed collection stream counts as nothing own', () async {
      remote.onFetchRandom = randomGames;

      final made = cubit(pool: pool, collection: own);
      await pumpEventQueue();
      own.fail();
      await pumpEventQueue();

      expect(ids(made), ['r-1']);
    });

    test('a collection stream that closes unanswered counts as nothing own, '
        'and the first draw does not wait for ever', () async {
      remote.onFetchRandom = randomGames;

      final made = cubit(pool: pool, collection: own);
      await pumpEventQueue();
      await own.close();
      await pumpEventQueue();

      expect(ids(made), ['r-1']);
    });

    test('never more than a shelf, whatever the server sends', () async {
      remote.onFetchRandom = (_) async => [
        for (var n = 0; n < 12; n++) summary('r-$n'),
      ];

      final made = await drawn();

      expect(ids(made), hasLength(SomethingToPlayCubit.shelfSize));
    });

    test('the first draw is draw 1', () async {
      final made = await drawn(items: [ownItem('o-1')]);

      expect(draw(made), 1);
    });
  });

  group('redraws', () {
    test('reshuffle draws again', () async {
      pool.onSample = (_) async => poolOf(['p-1']);
      final made = await drawn();
      expect(ids(made), ['p-1']);
      expect(draw(made), 1);

      pool.onSample = (_) async => poolOf(['p-2']);
      made.reshuffle();
      await pumpEventQueue();

      expect(pool.reads, hasLength(2));
      expect(ids(made), ['p-2']);
      expect(draw(made), 2);
    });

    test(
      'reshuffled twice before the first answer: only the last shows',
      () async {
        pool.onSample = (_) async => poolOf(['p-0']);
        final made = await drawn();

        final first = Completer<GamePoolSample>();
        final second = Completer<GamePoolSample>();
        final answers = [first, second];
        pool.onSample = (_) => answers.removeAt(0).future;
        final seen = <SomethingToPlayState>[];
        final subscription = made.stream.listen(seen.add);
        addTearDown(subscription.cancel);

        made
          ..reshuffle()
          ..reshuffle();
        await pumpEventQueue();
        expect(pool.reads, hasLength(3), reason: 'the second press reads anew');

        // In the worse order: the older answer lands last.
        second.complete(poolOf(['p-2']));
        await pumpEventQueue();
        expect(ids(made), ['p-2']);
        final shown = made.state;

        first.complete(poolOf(['p-1']));
        await pumpEventQueue();
        expect(made.state, same(shown));
        expect(seen, [shown]);
      },
    );

    test('a reshuffle during the first draw replaces it', () async {
      final first = Completer<GamePoolSample>();
      pool.onSample = (_) => first.future;
      final made = await drawn();

      pool.onSample = (_) async => poolOf(['p-2']);
      made.reshuffle();
      await pumpEventQueue();
      expect(ids(made), ['p-2']);

      first.complete(poolOf(['p-1']));
      await pumpEventQueue();
      expect(ids(made), ['p-2']);
      expect(draw(made), 1, reason: 'the first answer was never shown');
    });

    test(
      'a reshuffle before the collection has answered reads nothing',
      () async {
        final made = cubit(pool: pool, collection: own);
        await pumpEventQueue();

        made.reshuffle();
        await pumpEventQueue();

        expect(pool.reads, isEmpty);
        expect(made.state, const SomethingToPlayLoading());
      },
    );

    test('the old rows stay up during a reshuffle', () async {
      pool.onSample = (_) async => poolOf(['p-1']);
      final made = await drawn();
      final shown = made.state;

      final answer = Completer<GamePoolSample>();
      pool.onSample = (_) => answer.future;
      made.reshuffle();
      await pumpEventQueue();

      expect(made.state, same(shown));

      answer.complete(poolOf(['p-2']));
      await pumpEventQueue();
      expect(ids(made), ['p-2']);
    });

    group('drawIfNothing, for a page that has been uncovered', () {
      test('draws once the server has games it had none of', () async {
        remote.onFetchRandom = (_) async => const [];
        final made = await drawn();
        expect(made.state, const SomethingToPlayNothing());

        remote.onFetchRandom = randomGames;
        made.drawIfNothing();
        await pumpEventQueue();

        expect(ids(made), ['r-1']);
        expect(draw(made), 1);
      });

      test('draws after a first draw that failed while online', () async {
        pool.onSample = poolFails;
        remote.onFetchRandom = randomFails;
        final made = await drawn();
        expect(made.state, const SomethingToPlayNothing());

        pool.onSample = (_) async => poolOf(['p-1']);
        made.drawIfNothing();
        await pumpEventQueue();

        expect(ids(made), ['p-1']);
      });

      test('with rows up, draws nothing: the row is not swapped under a '
          'user who came back to it', () async {
        pool.onSample = (_) async => poolOf(['p-1']);
        final made = await drawn();
        final shown = made.state;
        final seen = <SomethingToPlayState>[];
        final subscription = made.stream.listen(seen.add);
        addTearDown(subscription.cancel);

        made.drawIfNothing();
        await pumpEventQueue();

        expect(pool.reads, hasLength(1));
        expect(made.state, same(shown));
        expect(seen, isEmpty);
      });

      test('before the first draw has landed, draws nothing', () async {
        final made = cubit(pool: pool, collection: own);
        await pumpEventQueue();

        made.drawIfNothing();
        await pumpEventQueue();

        expect(pool.reads, isEmpty);
        expect(made.state, const SomethingToPlayLoading());
      });

      test('offline, it asks nothing and Nothing stays', () async {
        connectivity.current = ConnectivityState.offline;
        final made = await drawn();
        expect(made.state, const SomethingToPlayNothing());
        final seen = <SomethingToPlayState>[];
        final subscription = made.stream.listen(seen.add);
        addTearDown(subscription.cancel);

        made.drawIfNothing();
        await pumpEventQueue();

        expect(pool.reads, isEmpty);
        expect(remote.calls, isEmpty);
        expect(seen, isEmpty);
      });

      test('leaves the state as it is until the answer lands', () async {
        remote.onFetchRandom = (_) async => const [];
        final made = await drawn();
        final answer = Completer<List<GameSummary>>();
        remote.onFetchRandom = (_) => answer.future;
        final seen = <SomethingToPlayState>[];
        final subscription = made.stream.listen(seen.add);
        addTearDown(subscription.cancel);

        made.drawIfNothing();
        await pumpEventQueue();
        expect(
          seen,
          isEmpty,
          reason: 'no spinner for a read in the background',
        );

        answer.complete([summary('r-1')]);
        await pumpEventQueue();
        expect(ids(made), ['r-1']);
      });
    });

    group('a draw that finds nothing, with rows up', () {
      /// Everything from here on fails.
      void readsFail() {
        pool.onSample = poolFails;
        remote.onFetchRandom = randomFails;
      }

      /// A cubit showing pool rows, and no own games.
      Future<SomethingToPlayCubit> showingPool() async {
        pool.onSample = (_) async => poolOf(['p-1']);
        final made = await drawn();
        expect(ids(made), ['p-1']);
        return made;
      }

      /// Records what [made] emits from here on.
      List<SomethingToPlayState> watch(SomethingToPlayCubit made) {
        final seen = <SomethingToPlayState>[];
        final subscription = made.stream.listen(seen.add);
        addTearDown(subscription.cancel);
        return seen;
      }

      test('a reshuffle offline keeps the rows, and asks nothing', () async {
        final made = await showingPool();
        connectivity.change(ConnectivityState.offline);
        await pumpEventQueue();
        final seen = watch(made);

        made.reshuffle();
        await pumpEventQueue();

        expect(ids(made), ['p-1']);
        expect(draw(made), 1, reason: 'nothing to announce, no row to reset');
        expect(seen, isEmpty);
        expect(pool.reads, hasLength(1));
        expect(remote.calls, isEmpty);
      });

      test('a reshuffle whose reads all fail keeps the rows', () async {
        final made = await showingPool();
        readsFail();
        final seen = watch(made);

        made.reshuffle();
        await pumpEventQueue();

        expect(ids(made), ['p-1']);
        expect(draw(made), 1);
        expect(seen, isEmpty);
      });

      test('a failed pool read and an empty random answer keep the rows: the '
          'pool could still have some', () async {
        final made = await showingPool();
        pool.onSample = poolFails;
        remote.onFetchRandom = (_) async => const [];

        made.reshuffle();
        await pumpEventQueue();

        expect(ids(made), ['p-1']);
      });

      group('a failure the server would only repeat keeps the rows too', () {
        for (final (key, error) in [
          (
            'a refused random read',
            const GamesForbiddenException('Random games returned 403'),
          ),
          (
            'an unreadable random answer',
            const GamesRemotePermanentException(
              'Failed to parse the Random games response',
            ),
          ),
        ]) {
          test(key, () async {
            pool.onSample = (_) async => poolOf(const []);
            remote.onFetchRandom = randomGames;
            final made = await drawn();
            expect(ids(made), ['r-1']);
            final seen = watch(made);

            remote.onFetchRandom = (_) async => throw error;
            made.reshuffle();
            await pumpEventQueue();

            expect(ids(made), ['r-1']);
            expect(seen, isEmpty);

            // Still not worth asking again on a reconnect.
            connectivity.change(ConnectivityState.offline);
            await pumpEventQueue();
            connectivity.change(ConnectivityState.online);
            await pumpEventQueue();
            expect(remote.calls, hasLength(2));
          });
        }

        test('a refused pool read and an empty random answer', () async {
          final made = await showingPool();
          pool.onSample = (_) async =>
              throw const HouseholdRemotePermanentException(
                'Household game pool sample returned 403',
              );
          remote.onFetchRandom = (_) async => const [];

          made.reshuffle();
          await pumpEventQueue();

          expect(ids(made), ['p-1']);
        });
      });

      test('the next reconnect draws again', () async {
        final made = await showingPool();
        connectivity.change(ConnectivityState.offline);
        await pumpEventQueue();
        made.reshuffle();
        await pumpEventQueue();

        pool.onSample = (_) async => poolOf(['p-2']);
        connectivity.change(ConnectivityState.online);
        await pumpEventQueue();

        expect(ids(made), ['p-2']);
        expect(draw(made), 2);
      });

      test('a reconnect redraw that fails again keeps the rows, and the one '
          'after it tries again: no flicker on a flaky link', () async {
        pool.onSample = poolFails;
        remote.onFetchRandom = randomGames;
        final made = await drawn();
        expect(ids(made), ['r-1']);
        final seen = watch(made);

        readsFail();
        connectivity.change(ConnectivityState.offline);
        await pumpEventQueue();
        connectivity.change(ConnectivityState.online);
        await pumpEventQueue();
        expect(pool.reads, hasLength(2));
        expect(ids(made), ['r-1']);
        expect(seen, isEmpty);

        connectivity.change(ConnectivityState.offline);
        await pumpEventQueue();
        pool.onSample = (_) async => poolOf(['p-1']);
        connectivity.change(ConnectivityState.online);
        await pumpEventQueue();

        expect(ids(made), ['p-1']);
        expect(draw(made), 2);
      });

      test('a first-hydrate redraw that fails keeps the rows', () async {
        final households = StreamController<List<Household>>.broadcast();
        addTearDown(households.close);
        remote.onFetchRandom = randomGames;
        final made = await drawn(households: households.stream);
        households.add(const []);
        await pumpEventQueue();
        final seen = watch(made);

        readsFail();
        households.add([household('h-1')]);
        await pumpEventQueue();

        expect(pool.reads, hasLength(2));
        expect(ids(made), ['r-1']);
        expect(seen, isEmpty);
      });

      test('a later reshuffle still works', () async {
        final made = await showingPool();
        readsFail();
        made.reshuffle();
        await pumpEventQueue();

        pool.onSample = (_) async => poolOf(['p-2']);
        made.reshuffle();
        await pumpEventQueue();

        expect(ids(made), ['p-2']);
        expect(draw(made), 2);
      });

      test('the collection filling afterwards still draws', () async {
        final made = await showingPool();
        readsFail();
        made.reshuffle();
        await pumpEventQueue();

        own.emit([ownItem('o-1')]);
        await pumpEventQueue();

        expect(ids(made), ['o-1']);
      });

      test('a complete empty answer still gives Nothing: the server says it '
          'has no games', () async {
        final made = await showingPool();
        pool.onSample = (_) async => poolOf(const []);
        remote.onFetchRandom = (_) async => const [];

        made.reshuffle();
        await pumpEventQueue();

        expect(made.state, const SomethingToPlayNothing());
      });

      test(
        'with no pool to ask, a complete empty answer still gives Nothing',
        () async {
          remote.onFetchRandom = randomGames;
          final made = cubit();
          await pumpEventQueue();
          expect(ids(made), ['r-1']);

          remote.onFetchRandom = (_) async => const [];
          made.reshuffle();
          await pumpEventQueue();

          expect(made.state, const SomethingToPlayNothing());
        },
      );

      test(
        'a game found gone after it still takes the last row down',
        () async {
          final gone = StreamController<String>.broadcast();
          addTearDown(gone.close);
          pool.onSample = (_) async => poolOf(['p-1']);
          final made = await drawn(gone: gone.stream);
          readsFail();
          made.reshuffle();
          await pumpEventQueue();
          expect(ids(made), ['p-1']);

          gone.add('p-1');
          await pumpEventQueue();

          expect(made.state, const SomethingToPlayNothing());
        },
      );
    });

    group('reconnecting', () {
      Future<void> reconnect() async {
        connectivity.change(ConnectivityState.offline);
        await pumpEventQueue();
        connectivity.change(ConnectivityState.online);
        await pumpEventQueue();
      }

      test('reconnecting draws again after a draw missing the pool', () async {
        connectivity.current = ConnectivityState.offline;
        final made = await drawn(items: [ownItem('o-1')]);
        expect(ids(made), ['o-1']);
        expect(pool.reads, isEmpty);

        pool.onSample = (_) async => poolOf(['p-1']);
        connectivity.change(ConnectivityState.online);
        await pumpEventQueue();

        expect(pool.reads, [10]);
        expect(ids(made), unorderedEquals(['o-1', 'p-1']));
        expect(draw(made), 2);
      });

      test('reconnecting draws again after a failed pool read', () async {
        pool.onSample = poolFails;
        final made = await drawn(items: [ownItem('o-1')]);

        pool.onSample = (_) async => poolOf(['p-1']);
        await reconnect();

        expect(ids(made), unorderedEquals(['o-1', 'p-1']));
      });

      test('reconnecting draws again after a failed random read', () async {
        remote.onFetchRandom = randomFails;
        final made = await drawn();
        expect(made.state, const SomethingToPlayNothing());

        remote.onFetchRandom = randomGames;
        await reconnect();

        expect(ids(made), ['r-1']);
      });

      group('a failure the server would only repeat is not incomplete', () {
        for (final (key, error) in [
          (
            'a refused random read',
            const GamesForbiddenException('Random games returned 403'),
          ),
          (
            'a rejected random read',
            const GamesRemotePermanentException('Random games returned 400'),
          ),
        ]) {
          test(key, () async {
            remote.onFetchRandom = (_) async => throw error;
            final made = await drawn();
            expect(made.state, const SomethingToPlayNothing());
            expect(remote.calls, hasLength(1));

            await reconnect();

            expect(pool.reads, hasLength(1));
            expect(remote.calls, hasLength(1));
          });
        }

        test('a refused pool read', () async {
          pool.onSample = (_) async =>
              throw const HouseholdRemotePermanentException(
                'Household game pool sample returned 403',
              );
          final made = await drawn(items: [ownItem('o-1')]);
          expect(ids(made), ['o-1']);

          await reconnect();

          expect(pool.reads, hasLength(1));
          expect(draw(made), 1);
        });

        test('a transient one still is', () async {
          pool.onSample = (_) async =>
              throw const HouseholdRemoteTransientException(
                'Household game pool sample returned 503',
              );
          final made = await drawn(items: [ownItem('o-1')]);

          pool.onSample = (_) async => poolOf(['p-1']);
          await reconnect();

          expect(ids(made), unorderedEquals(['o-1', 'p-1']));
        });
      });

      test('reconnecting after a complete draw does not', () async {
        pool.onSample = (_) async => poolOf(['p-1']);
        final made = await drawn(items: [ownItem('o-1')]);
        final shown = made.state;

        await reconnect();

        expect(pool.reads, hasLength(1));
        expect(made.state, same(shown));
      });

      test('with no pool to ask, reconnecting does not', () async {
        connectivity.current = ConnectivityState.offline;
        final made = cubit(collection: own);
        await pumpEventQueue();
        own.emit([ownItem('o-1')]);
        await pumpEventQueue();
        final shown = made.state;

        connectivity.change(ConnectivityState.online);
        await pumpEventQueue();

        expect(made.state, same(shown));
        expect(remote.calls, isEmpty);
      });

      test('with no pool to ask, offline with nothing own, reconnecting reads '
          'the random games it skipped', () async {
        connectivity.current = ConnectivityState.offline;
        remote.onFetchRandom = randomGames;
        final made = cubit();
        await pumpEventQueue();
        expect(made.state, const SomethingToPlayNothing());

        connectivity.change(ConnectivityState.online);
        await pumpEventQueue();

        expect(ids(made), ['r-1']);
      });

      test('connectivity repeating itself is not a reconnection', () async {
        pool.onSample = poolFails;
        await drawn(items: [ownItem('o-1')]);
        expect(pool.reads, hasLength(1));

        connectivity.change(ConnectivityState.online);
        await pumpEventQueue();

        expect(pool.reads, hasLength(1));
      });

      test('going offline does not draw', () async {
        pool.onSample = poolFails;
        final made = await drawn(items: [ownItem('o-1')]);
        final shown = made.state;

        connectivity.change(ConnectivityState.offline);
        await pumpEventQueue();

        expect(made.state, same(shown));
      });

      test('reconnecting while a read is out starts over: that read may have '
          'gone with the connection', () async {
        pool.onSample = (_) async => poolOf(['p-0']);
        final made = await drawn();

        final doomed = Completer<GamePoolSample>();
        pool.onSample = (_) => doomed.future;
        made.reshuffle();
        await pumpEventQueue();

        pool.onSample = (_) async => poolOf(['p-1']);
        await reconnect();
        expect(ids(made), ['p-1']);

        doomed.completeError(StateError('the connection went'));
        await pumpEventQueue();
        expect(ids(made), ['p-1']);
      });

      test('before the collection has answered, it leaves the draw to the '
          'first answer', () async {
        connectivity.current = ConnectivityState.offline;
        final made = cubit(pool: pool, collection: own);
        await pumpEventQueue();

        connectivity.change(ConnectivityState.online);
        await pumpEventQueue();
        expect(pool.reads, isEmpty);

        own.emit([ownItem('o-1')]);
        await pumpEventQueue();
        expect(pool.reads, [10]);
        expect(ids(made), ['o-1']);
      });
    });

    group('a first hydrate', () {
      late StreamController<List<Household>> households;

      setUp(() => households = StreamController.broadcast());
      tearDown(() => households.close());

      test('after a server-random draw, the collection going from empty to '
          'filled draws again', () async {
        remote.onFetchRandom = randomGames;
        final made = await drawn();
        expect(ids(made), ['r-1']);

        own.emit([ownItem('o-1')]);
        await pumpEventQueue();

        expect(ids(made), ['o-1']);
        expect(pool.reads, hasLength(2));
        expect(draw(made), 2);
      });

      test('after a server-random draw, households going from empty to filled '
          'draws again', () async {
        remote.onFetchRandom = randomGames;
        final made = await drawn(households: households.stream);
        households.add(const []);
        await pumpEventQueue();
        expect(ids(made), ['r-1']);
        expect(pool.reads, hasLength(1));

        pool.onSample = (_) async => poolOf(['p-1']);
        households.add([household('h-1')]);
        await pumpEventQueue();

        expect(pool.reads, hasLength(2));
        expect(ids(made), ['p-1']);
      });

      test('households first answering filled is not a change', () async {
        remote.onFetchRandom = randomGames;
        final made = await drawn(households: households.stream);

        households.add([household('h-1')]);
        await pumpEventQueue();

        expect(pool.reads, hasLength(1));
        expect(draw(made), 1);
      });

      test('households filling after a draw of pool or own games does not '
          'draw', () async {
        final made = await drawn(
          items: [ownItem('o-1')],
          households: households.stream,
        );
        households.add(const []);
        await pumpEventQueue();

        households.add([household('h-1')]);
        await pumpEventQueue();

        expect(pool.reads, hasLength(1));
        expect(draw(made), 1);
      });

      test('it answers once: the draw it starts is what counts next', () async {
        remote.onFetchRandom = randomGames;
        final made = await drawn(households: households.stream);
        households.add(const []);
        await pumpEventQueue();

        own.emit([ownItem('o-1')]);
        await pumpEventQueue();
        expect(draw(made), 2);

        households.add([household('h-1')]);
        await pumpEventQueue();

        expect(draw(made), 2, reason: 'own games are up, not random ones');
      });

      test('the collection filling while the random read is out starts over, '
          'so its answer is never shown', () async {
        final answer = Completer<List<GameSummary>>();
        remote.onFetchRandom = (_) => answer.future;
        final made = await drawn();

        own.emit([ownItem('o-1')]);
        await pumpEventQueue();
        expect(ids(made), ['o-1']);

        answer.complete([summary('r-1')]);
        await pumpEventQueue();
        expect(ids(made), ['o-1']);
      });

      test(
        'the collection filling after a draw that found nothing shows it',
        () async {
          remote.onFetchRandom = randomFails;
          final made = await drawn();
          expect(made.state, const SomethingToPlayNothing());

          own.emit([ownItem('o-1')]);
          await pumpEventQueue();

          expect(ids(made), ['o-1']);
        },
      );

      test('a collection that failed first, and fills later, counts', () async {
        remote.onFetchRandom = randomGames;
        final made = cubit(pool: pool, collection: own);
        await pumpEventQueue();
        own.fail();
        await pumpEventQueue();
        expect(ids(made), ['r-1']);

        own.emit([ownItem('o-1')]);
        await pumpEventQueue();

        expect(ids(made), ['o-1']);
      });

      test('a later collection change does not redraw', () async {
        remote.onFetchRandom = randomGames;
        final made = await drawn();
        own.emit([ownItem('o-1')]);
        await pumpEventQueue();
        expect(draw(made), 2);
        final shown = made.state;

        own.emit([ownItem('o-1'), ownItem('o-2')]);
        await pumpEventQueue();
        own.emit(const []);
        await pumpEventQueue();
        own.emit([ownItem('o-3')]);
        await pumpEventQueue();

        expect(made.state, same(shown));
        expect(pool.reads, hasLength(2));
      });

      test('a later collection change reaches the next draw', () async {
        final made = await drawn(items: [ownItem('o-1')]);

        own.emit([ownItem('o-2')]);
        await pumpEventQueue();
        expect(ids(made), ['o-1']);

        made.reshuffle();
        await pumpEventQueue();
        expect(ids(made), ['o-2']);
      });

      test(
        'a stream failing after its first answer keeps what it said',
        () async {
          final made = await drawn(items: [ownItem('o-1')]);

          own.fail();
          await pumpEventQueue();
          made.reshuffle();
          await pumpEventQueue();

          expect(ids(made), ['o-1']);
        },
      );
    });

    group('a game found gone', () {
      late StreamController<String> gone;

      setUp(() => gone = StreamController.broadcast());
      tearDown(() => gone.close());

      test('a game found gone comes down with no redraw', () async {
        final made = await drawn(
          items: [ownItem('o-1'), ownItem('o-2')],
          gone: gone.stream,
        );

        gone.add('o-1');
        await pumpEventQueue();

        expect(ids(made), ['o-2']);
        expect(pool.reads, hasLength(1));
        expect(draw(made), 1, reason: 'the row must not jump to its start');
      });

      test('losing the last row is Nothing, with no redraw', () async {
        final made = await drawn(items: [ownItem('o-1')], gone: gone.stream);

        gone.add('o-1');
        await pumpEventQueue();

        expect(made.state, const SomethingToPlayNothing());
        expect(pool.reads, hasLength(1));
        expect(remote.calls, isEmpty);
      });

      test('a game not on the row changes nothing', () async {
        final made = await drawn(items: [ownItem('o-1')], gone: gone.stream);
        final shown = made.state;

        gone.add('other');
        await pumpEventQueue();

        expect(made.state, same(shown));
      });

      test('it stays out of later draws, wherever they come from', () async {
        pool.onSample = (_) async => poolOf(['p-1', 'p-2']);
        final made = await drawn(
          items: [ownItem('o-1'), ownItem('o-2')],
          gone: gone.stream,
        );

        gone
          ..add('p-1')
          ..add('o-1');
        await pumpEventQueue();
        made.reshuffle();
        await pumpEventQueue();

        expect(ids(made), unorderedEquals(['p-2', 'o-2']));
      });

      test('it stays out of random games too', () async {
        remote.onFetchRandom = (_) async => [summary('r-1'), summary('r-2')];
        final made = await drawn(gone: gone.stream);

        gone.add('r-1');
        await pumpEventQueue();
        made.reshuffle();
        await pumpEventQueue();

        expect(ids(made), ['r-2']);
      });

      test(
        'found gone while a read is out, it stays out of that answer',
        () async {
          final answer = Completer<GamePoolSample>();
          pool.onSample = (_) => answer.future;
          final made = await drawn(gone: gone.stream);

          gone.add('p-1');
          await pumpEventQueue();
          answer.complete(poolOf(['p-1', 'p-2']));
          await pumpEventQueue();

          expect(ids(made), ['p-2']);
        },
      );
    });

    test('nothing emits after close', () async {
      pool.onSample = (_) async => poolOf(['p-0']);
      final households = StreamController<List<Household>>.broadcast();
      addTearDown(households.close);
      final gone = StreamController<String>.broadcast();
      addTearDown(gone.close);
      final made = await drawn(
        households: households.stream,
        gone: gone.stream,
      );

      final answer = Completer<GamePoolSample>();
      pool.onSample = (_) => answer.future;
      made.reshuffle();
      await pumpEventQueue();
      final shown = made.state;

      final seen = <SomethingToPlayState>[];
      final subscription = made.stream.listen(seen.add);
      addTearDown(subscription.cancel);
      await made.close();

      answer.complete(poolOf(['p-1']));
      own.emit([ownItem('o-1')]);
      gone.add('p-0');
      households
        ..add(const [])
        ..add([household('h-1')]);
      connectivity.change(ConnectivityState.offline);
      await pumpEventQueue();
      connectivity.change(ConnectivityState.online);
      made.reshuffle();
      await pumpEventQueue();

      expect(seen, isEmpty);
      expect(made.state, same(shown));
    });

    test('an answer landing in close\'s own turn is dropped', () async {
      pool.onSample = (_) async => poolOf(['p-0']);
      final made = await drawn();

      final answer = Completer<GamePoolSample>();
      pool.onSample = (_) => answer.future;
      made.reshuffle();
      await pumpEventQueue();
      final shown = made.state;

      final closed = made.close();
      answer.complete(poolOf(['p-1']));
      await closed;
      await pumpEventQueue();

      expect(made.state, same(shown));
    });
  });
}
