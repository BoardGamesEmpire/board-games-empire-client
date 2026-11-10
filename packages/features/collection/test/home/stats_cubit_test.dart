import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_connectivity.dart';
import '../support/fake_stats_sources.dart';
import '../support/list_items.dart';

/// A pass running, with none yet landed.
const _running = Hydration(state: HydrationState.running);

/// A pass landed rows.
const _landed = Hydration(state: HydrationState.refreshed, everRefreshed: true);

/// A first pass that failed, so that nothing is confirmed.
const _failedFirst = Hydration(
  state: HydrationState.failed,
  lastPassFailed: true,
);

/// A pool of [gameCount] games, as the server answers it.
GamePoolSample _sample(int gameCount) =>
    (games: const <GameSummary>[], gameCount: gameCount);

/// Lets everything already scheduled run.
Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeOwnGames own;
  late FakeGamePool pool;
  late FakeConnectivity connectivity;
  late StreamController<List<Household>> households;
  late StreamController<Hydration> collectionHydration;
  late StreamController<Hydration> householdHydration;

  setUp(() {
    own = FakeOwnGames();
    pool = FakeGamePool();
    connectivity = FakeConnectivity();
    households = StreamController<List<Household>>.broadcast();
    collectionHydration = StreamController<Hydration>.broadcast();
    householdHydration = StreamController<Hydration>.broadcast();
  });

  // Not awaited: a cubit made under a fake clock leaves the fake's stream
  // waiting on microtasks that nothing runs once the test has ended.
  tearDown(() {
    unawaited(own.close());
    unawaited(connectivity.close());
    unawaited(households.close());
    unawaited(collectionHydration.close());
    unawaited(householdHydration.close());
  });

  /// A cubit over the fakes. Each flag leaves one input out, as a composition
  /// without it does.
  StatsCubit build({
    bool collectionHydrate = false,
    bool withHouseholds = true,
    bool householdHydrate = false,
    bool withPool = true,
    bool withConnectivity = true,
  }) {
    final cubit = StatsCubit(
      collection: own,
      collectionHydration: collectionHydrate
          ? collectionHydration.stream
          : null,
      households: withHouseholds ? households.stream : null,
      householdHydration: householdHydrate ? householdHydration.stream : null,
      pool: withPool ? pool : null,
      connectivity: withConnectivity ? connectivity : null,
    );
    addTearDown(cubit.close);
    return cubit;
  }

  /// Every state [cubit] emits from here on.
  List<StatsState> record(StatsCubit cubit) {
    final states = <StatsState>[];
    final subscription = cubit.stream.listen(states.add);
    addTearDown(subscription.cancel);
    return states;
  }

  /// Reads that wait for the test to answer them, newest last.
  List<Completer<GamePoolSample>> holdReads() {
    final held = <Completer<GamePoolSample>>[];
    pool.onSample = (_) {
      final read = Completer<GamePoolSample>();
      held.add(read);
      return read.future;
    };
    return held;
  }

  group('the collection', () {
    test('counts distinct games, not entries', () async {
      final cubit = build();

      own.emit([
        listItem('a', gameId: 'g-1'),
        listItem('b', gameId: 'g-1', medium: GameMedium.digital),
        listItem('c', gameId: 'g-2'),
      ]);
      await _settle();

      expect(cubit.state.collectionGames, 2);
    });

    test('is null until the cache answers', () async {
      final cubit = build();
      await _settle();

      expect(cubit.state, const StatsState());
      expect(cubit.state.collectionGames, isNull);
    });

    test('an empty collection during a first pass is null, then 0 once it '
        'lands', () async {
      final cubit = build(collectionHydrate: true);

      collectionHydration.add(_running);
      own.emit(const []);
      await _settle();
      expect(cubit.state.collectionGames, isNull);

      collectionHydration.add(_landed);
      await _settle();
      expect(cubit.state.collectionGames, 0);
    });

    test(
      'an empty collection is 0 where there is no hydrate to wait for',
      () async {
        final cubit = build();

        own.emit(const []);
        await _settle();

        expect(cubit.state.collectionGames, 0);
      },
    );

    test('an empty collection that only a failed pass has seen is null, '
        'because a failure confirms nothing', () async {
      final cubit = build(collectionHydrate: true);

      collectionHydration.add(_failedFirst);
      own.emit(const []);
      await _settle();

      expect(cubit.state.collectionGames, isNull);
    });

    test('an empty collection is still 0 after a later pass fails', () async {
      final cubit = build(collectionHydrate: true);
      collectionHydration.add(_landed);
      own.emit(const []);
      await _settle();

      collectionHydration.add(
        const Hydration(
          state: HydrationState.failed,
          everRefreshed: true,
          lastPassFailed: true,
        ),
      );
      await _settle();

      expect(cubit.state.collectionGames, 0);
    });

    test('rows count whatever the hydrate says', () async {
      final cubit = build(collectionHydrate: true);

      collectionHydration.add(_running);
      own.emit([listItem('a')]);
      await _settle();
      expect(cubit.state.collectionGames, 1);

      collectionHydration.add(_failedFirst);
      await _settle();
      expect(cubit.state.collectionGames, 1);
    });

    test('a hydrate not heard from yet is a pass nobody has landed', () async {
      final cubit = build(collectionHydrate: true);

      own.emit(const []);
      await _settle();

      expect(cubit.state.collectionGames, isNull);
    });

    test('a failed collection stream is null', () async {
      final cubit = build();
      own.emit([listItem('a')]);
      await _settle();
      expect(cubit.state.collectionGames, 1);

      own.fail();
      await _settle();
      expect(cubit.state.collectionGames, isNull);

      own.emit([listItem('a'), listItem('b')]);
      await _settle();
      expect(cubit.state.collectionGames, 2, reason: 'the next rows clear it');
    });

    test('a stream that fails before it answers is null', () async {
      final cubit = build();

      own.fail();
      await _settle();

      expect(cubit.state.collectionGames, isNull);
    });

    test('a stream that closes before answering leaves it null', () async {
      final cubit = build();
      final states = record(cubit);

      await own.close();
      await _settle();

      expect(cubit.state, const StatsState());
      expect(states, isEmpty);
    });

    test('a stream that closes after answering keeps the count', () async {
      final cubit = build();
      own.emit([listItem('a')]);
      await _settle();

      await own.close();
      await _settle();

      expect(cubit.state.collectionGames, 1);
    });
  });

  group('the households', () {
    test('asks for size 1 and shows gameCount', () async {
      pool.answer(7);
      final cubit = build();

      households.add([household('h1')]);
      await _settle();

      expect(pool.reads, [1]);
      expect(cubit.state.households, const HouseholdStatCount(7));
    });

    test(
      'gameCount 0 with a household is a count of 0, not the prompt',
      () async {
        pool.answer(0);
        final cubit = build(householdHydrate: true);
        householdHydration.add(_landed);

        households.add([household('h1')]);
        await _settle();

        expect(cubit.state.households, const HouseholdStatCount(0));
      },
    );

    test('is hidden until the households answer', () async {
      pool.answer(7);
      final cubit = build();
      await _settle();

      expect(cubit.state.households, const HouseholdStatHidden());
      expect(pool.reads, isEmpty);
    });

    test('a null households stream is hidden, and asks for nothing', () async {
      final cubit = build(withHouseholds: false)..reload();
      await _settle();

      expect(cubit.state.households, const HouseholdStatHidden());
      expect(pool.reads, isEmpty);
    });

    test('a household with no pool to ask is hidden', () async {
      final cubit = build(withPool: false);

      households.add([household('h1')]);
      await _settle();

      expect(cubit.state.households, const HouseholdStatHidden());
    });

    test('a failed households stream is hidden, and drops the count', () async {
      pool.answer(7);
      final cubit = build();
      households.add([household('h1')]);
      await _settle();

      households.addError(StateError('the households failed'));
      await _settle();
      expect(cubit.state.households, const HouseholdStatHidden());

      households.add([household('h1')]);
      await _settle();
      expect(
        cubit.state.households,
        const HouseholdStatCount(7),
        reason: 'the next rows read again',
      );
      expect(pool.reads, [1, 1]);
    });

    test('a stream that closes before answering is hidden', () async {
      final cubit = build(householdHydrate: true);
      householdHydration.add(_landed);
      final states = record(cubit);

      await households.close();
      await _settle();

      expect(cubit.state.households, const HouseholdStatHidden());
      expect(states, isEmpty);
    });

    test('a stream that closes after answering keeps the count', () async {
      pool.answer(7);
      final cubit = build();
      households.add([household('h1')]);
      await _settle();

      await households.close();
      await _settle();

      expect(cubit.state.households, const HouseholdStatCount(7));
    });
  });

  group('the prompt', () {
    test(
      'no cached household, a pass landed: the prompt, with no request',
      () async {
        final cubit = build(householdHydrate: true);

        householdHydration.add(_landed);
        households.add(const []);
        await _settle();

        expect(cubit.state.households, const HouseholdStatPrompt());
        expect(pool.reads, isEmpty);
      },
    );

    test('the order the two arrive in does not matter', () async {
      final cubit = build(householdHydrate: true);

      households.add(const []);
      await _settle();
      expect(cubit.state.households, const HouseholdStatHidden());

      householdHydration.add(_landed);
      await _settle();
      expect(cubit.state.households, const HouseholdStatPrompt());
    });

    test('no cached household, a pass running: hidden', () async {
      final cubit = build(householdHydrate: true);

      householdHydration.add(_running);
      households.add(const []);
      await _settle();

      expect(cubit.state.households, const HouseholdStatHidden());
    });

    test('no cached household, the last pass failed: hidden', () async {
      final cubit = build(householdHydrate: true);

      householdHydration.add(_failedFirst);
      households.add(const []);
      await _settle();

      expect(cubit.state.households, const HouseholdStatHidden());
    });

    test(
      'no cached household, a pass failed after one landed: hidden',
      () async {
        final cubit = build(householdHydrate: true);

        householdHydration.add(
          const Hydration(
            state: HydrationState.failed,
            everRefreshed: true,
            lastPassFailed: true,
          ),
        );
        households.add(const []);
        await _settle();

        expect(cubit.state.households, const HouseholdStatHidden());
      },
    );

    test('no cached household, a status present but idle: hidden', () async {
      final cubit = build(householdHydrate: true);

      householdHydration.add(const Hydration());
      households.add(const []);
      await _settle();

      expect(cubit.state.households, const HouseholdStatHidden());
    });

    test('no cached household, a status not heard from yet: hidden', () async {
      final cubit = build(householdHydrate: true);

      households.add(const []);
      await _settle();

      expect(cubit.state.households, const HouseholdStatHidden());
    });

    test('no cached household, no status at all: the prompt', () async {
      final cubit = build();

      households.add(const []);
      await _settle();

      expect(cubit.state.households, const HouseholdStatPrompt());
      expect(pool.reads, isEmpty);
    });

    test('a pass running after one landed still counts as settled', () async {
      final cubit = build(householdHydrate: true);

      householdHydration.add(_landed);
      households.add(const []);
      await _settle();
      householdHydration.add(
        const Hydration(state: HydrationState.running, everRefreshed: true),
      );
      await _settle();

      expect(cubit.state.households, const HouseholdStatPrompt());
    });

    test('a landed pass says nothing until the households answer', () async {
      final cubit = build(householdHydrate: true);

      householdHydration.add(_landed);
      await _settle();

      expect(cubit.state.households, const HouseholdStatHidden());
    });

    test('someone with households never sees it', () async {
      pool.answer(3);
      final cubit = build(householdHydrate: true);
      final states = record(cubit);

      householdHydration.add(_running);
      households.add([household('h1')]);
      await _settle();
      householdHydration.add(_landed);
      await _settle();

      expect(states.where((s) => s.households is HouseholdStatPrompt), isEmpty);
      expect(cubit.state.households, const HouseholdStatCount(3));
    });

    test(
      'is told offline too: it is a fact about the list, not a count',
      () async {
        connectivity.current = ConnectivityState.offline;
        final cubit = build(householdHydrate: true);

        householdHydration.add(_landed);
        households.add(const []);
        await _settle();

        expect(cubit.state.households, const HouseholdStatPrompt());
      },
    );

    test('leaving the last household drops the count for the prompt', () async {
      pool.answer(7);
      final cubit = build(householdHydrate: true);
      householdHydration.add(_landed);
      households.add([household('h1')]);
      await _settle();
      expect(cubit.state.households, const HouseholdStatCount(7));

      households.add(const []);
      await _settle();

      expect(cubit.state.households, const HouseholdStatPrompt());
    });

    test('leaving the last household discards a read in flight', () async {
      final held = holdReads();
      final cubit = build(householdHydrate: true);
      householdHydration.add(_landed);
      households.add([household('h1')]);
      await _settle();
      households.add(const []);
      await _settle();

      held.single.complete(_sample(7));
      await _settle();

      expect(cubit.state.households, const HouseholdStatPrompt());
    });
  });

  group('reading the count', () {
    test('households going from empty to filled reads the count', () async {
      pool.answer(7);
      final cubit = build(householdHydrate: true);
      householdHydration.add(_landed);
      households.add(const []);
      await _settle();
      expect(pool.reads, isEmpty);

      households.add([household('h1')]);
      await _settle();

      expect(pool.reads, [1]);
      expect(cubit.state.households, const HouseholdStatCount(7));
    });

    test('households changing while filled does not read again', () async {
      pool.answer(7);
      build();
      households.add([household('h1')]);
      await _settle();

      households.add([household('h1'), household('h2')]);
      await _settle();

      expect(pool.reads, [1]);
    });

    test('offline: hidden, even with an earlier count', () async {
      pool.answer(7);
      final cubit = build();
      households.add([household('h1')]);
      await _settle();
      expect(cubit.state.households, const HouseholdStatCount(7));

      connectivity.change(ConnectivityState.offline);
      await _settle();

      expect(cubit.state.households, const HouseholdStatHidden());
      expect(pool.reads, [1], reason: 'going offline asks nothing');
    });

    test(
      'built offline: hidden, with no request, until it reconnects',
      () async {
        connectivity.current = ConnectivityState.offline;
        pool.answer(7);
        final cubit = build();

        households.add([household('h1')]);
        await _settle();
        cubit.reload();
        await _settle();
        expect(cubit.state.households, const HouseholdStatHidden());
        expect(pool.reads, isEmpty);

        connectivity.change(ConnectivityState.online);
        await _settle();
        expect(pool.reads, [1]);
        expect(cubit.state.households, const HouseholdStatCount(7));
      },
    );

    test(
      'an earlier count does not come back while the reconnect reads',
      () async {
        pool.answer(7);
        final cubit = build();
        households.add([household('h1')]);
        await _settle();
        connectivity.change(ConnectivityState.offline);
        await _settle();
        final held = holdReads();

        connectivity.change(ConnectivityState.online);
        await _settle();
        expect(cubit.state.households, const HouseholdStatHidden());

        held.single.complete(_sample(9));
        await _settle();
        expect(cubit.state.households, const HouseholdStatCount(9));
      },
    );

    test('going offline discards a read in flight', () async {
      final held = holdReads();
      final cubit = build();
      households.add([household('h1')]);
      await _settle();

      connectivity.change(ConnectivityState.offline);
      await _settle();
      held.single.complete(_sample(7));
      await _settle();

      expect(cubit.state.households, const HouseholdStatHidden());
    });

    test('a failed read: hidden, even with an earlier count', () async {
      pool.answer(7);
      final cubit = build();
      households.add([household('h1')]);
      await _settle();
      expect(cubit.state.households, const HouseholdStatCount(7));

      pool.fail();
      cubit.reload();
      await _settle();
      expect(cubit.state.households, const HouseholdStatHidden());

      pool.answer(8);
      cubit.reload();
      await _settle();
      expect(cubit.state.households, const HouseholdStatCount(8));
    });

    test('a first read that fails is hidden', () async {
      pool.fail();
      final cubit = build();

      households.add([household('h1')]);
      await _settle();

      expect(cubit.state.households, const HouseholdStatHidden());
    });

    test('a reload keeps the last count up until its answer lands', () async {
      pool.answer(7);
      final cubit = build();
      households.add([household('h1')]);
      await _settle();
      final states = record(cubit);
      final held = holdReads();

      cubit.reload();
      await _settle();
      expect(cubit.state.households, const HouseholdStatCount(7));

      held.single.complete(_sample(8));
      await _settle();

      expect(states, [const StatsState(households: HouseholdStatCount(8))]);
    });

    test(
      'a reload that is out keeps the count through other changes',
      () async {
        pool.answer(7);
        final cubit = build();
        households.add([household('h1')]);
        await _settle();
        holdReads();

        cubit.reload();
        own.emit([listItem('a')]);
        await _settle();

        expect(
          cubit.state,
          const StatsState(
            collectionGames: 1,
            households: HouseholdStatCount(7),
          ),
        );
      },
    );

    test('a read that finds the same count says nothing', () async {
      pool.answer(7);
      final cubit = build();
      households.add([household('h1')]);
      await _settle();
      final states = record(cubit);

      cubit.reload();
      await _settle();

      expect(pool.reads, [1, 1]);
      expect(states, isEmpty);
    });

    test('reload and reconnecting read again; a replayed connectivity state '
        'does not', () async {
      pool.answer(7);
      final cubit = build();
      households.add([household('h1')]);
      await _settle();
      expect(pool.reads, [
        1,
      ], reason: 'the replay of the current state is not a change');

      cubit.reload();
      await _settle();
      expect(pool.reads, [1, 1]);

      connectivity.change(ConnectivityState.offline);
      await _settle();
      expect(pool.reads, [1, 1], reason: 'going offline asks nothing');
      connectivity.change(ConnectivityState.online);
      await _settle();
      expect(pool.reads, [1, 1, 1]);

      connectivity.change(ConnectivityState.online);
      await _settle();
      expect(pool.reads, [1, 1, 1], reason: 'online again is not a change');
    });

    test('an unknown connection says nothing new', () async {
      pool.answer(7);
      final cubit = build();
      households.add([household('h1')]);
      await _settle();

      connectivity.change(ConnectivityState.unknown);
      await _settle();

      expect(pool.reads, [1]);
      expect(cubit.state.households, const HouseholdStatCount(7));
    });

    test('a reload with no households asks for nothing', () async {
      final cubit = build(householdHydrate: true);
      householdHydration.add(_landed);
      households.add(const []);
      await _settle();

      cubit.reload();
      await _settle();

      expect(pool.reads, isEmpty);
    });

    test('a late answer after a newer read is discarded', () async {
      final held = holdReads();
      final cubit = build();
      households.add([household('h1')]);
      await _settle();
      cubit.reload();
      await _settle();
      expect(held, hasLength(2));

      held[1].complete(_sample(9));
      await _settle();
      expect(cubit.state.households, const HouseholdStatCount(9));

      held[0].complete(_sample(5));
      await _settle();
      expect(cubit.state.households, const HouseholdStatCount(9));
    });

    test('an older answer that lands first is discarded too', () async {
      final held = holdReads();
      final cubit = build();
      households.add([household('h1')]);
      await _settle();
      cubit.reload();
      await _settle();

      held[0].complete(_sample(5));
      await _settle();
      expect(cubit.state.households, const HouseholdStatHidden());

      held[1].complete(_sample(9));
      await _settle();
      expect(cubit.state.households, const HouseholdStatCount(9));
    });

    test('a late failure after a newer read is discarded', () async {
      final held = holdReads();
      final cubit = build();
      households.add([household('h1')]);
      await _settle();
      cubit.reload();
      await _settle();

      held[1].complete(_sample(9));
      await _settle();
      held[0].completeError(StateError('the old read failed'));
      await _settle();

      expect(cubit.state.households, const HouseholdStatCount(9));
    });
  });

  group('closing', () {
    test('nothing emits after close', () async {
      final held = holdReads();
      final cubit = build(collectionHydrate: true, householdHydrate: true);
      households.add([household('h1')]);
      await _settle();
      final states = record(cubit);

      await cubit.close();
      held.single.complete(_sample(7));
      own.emit([listItem('a')]);
      households.add(const []);
      collectionHydration.add(_landed);
      householdHydration.add(_landed);
      connectivity
        ..change(ConnectivityState.offline)
        ..change(ConnectivityState.online);
      cubit.reload();
      await _settle();

      expect(states, isEmpty);
      expect(held, hasLength(1), reason: 'and nothing reads');
    });

    test('releases every stream it listened to', () async {
      final cubit = build(collectionHydrate: true, householdHydrate: true);
      await _settle();
      expect(own.listened, isTrue);
      expect(connectivity.listened, isTrue);
      expect(households.hasListener, isTrue);
      expect(collectionHydration.hasListener, isTrue);
      expect(householdHydration.hasListener, isTrue);

      await cubit.close();

      expect(own.listened, isFalse);
      expect(connectivity.listened, isFalse);
      expect(households.hasListener, isFalse);
      expect(collectionHydration.hasListener, isFalse);
      expect(householdHydration.hasListener, isFalse);
    });

    test('an answer that lands while it is closing is dropped', () async {
      final held = holdReads();
      final cubit = build();
      households.add([household('h1')]);
      await _settle();
      final states = record(cubit);

      final closing = cubit.close();
      held.single.complete(_sample(7));
      await closing;
      await _settle();

      expect(states, isEmpty);
    });

    test('a read in flight that fails after close is quiet', () async {
      final held = holdReads();
      final cubit = build();
      households.add([household('h1')]);
      await _settle();

      await cubit.close();
      held.single.completeError(StateError('the session ended'));
      await _settle();

      expect(cubit.isClosed, isTrue);
    });
  });
}
