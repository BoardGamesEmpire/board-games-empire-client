import 'dart:async';

import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_collection_remote.dart';

class _MockGameCollectionRepository extends Mock
    implements GameCollectionRepository {}

class _MockGameRepository extends Mock implements GameRepository {}

/// Answers [confirm] with [answer], recording whom it was asked about
/// (#432).
class _FakeIdentityGuard implements SessionIdentityGuard {
  _FakeIdentityGuard({required this.answer});

  final SessionConfirmation answer;
  final askedFor = <String>[];

  @override
  Future<SessionConfirmation> confirm(String userId) async {
    askedFor.add(userId);
    return answer;
  }
}

Future<PaginatedResult<GameCollectionWithSummary>> _empty() async =>
    const PaginatedResult(
      items: [],
      meta: PaginationMeta(
        page: 1,
        limit: 100,
        total: 0,
        totalPages: 0,
        hasMore: false,
      ),
    );

Future<PaginatedResult<GameCollectionWithSummary>> _offline() async =>
    throw const GameCollectionRemoteTransientException('offline');

const _server = ScopedServer(serverId: 'server-1', displayName: 'My Server');

void main() {
  late DependencyContainerImpl container;
  late FakeCollectionRemote remote;

  setUp(() {
    container = DependencyContainerImpl();
    remote = FakeCollectionRemote((_) => _empty());
  });

  tearDown(() async => container.dispose());

  /// Registers what the hydrate needs, less whatever a test leaves out.
  void register({
    bool client = true,
    bool collection = true,
    bool games = true,
  }) {
    // A pass reads the removal mark first, and every page is written, empty
    // ones too, so the read and both writes must answer.
    if (collection) {
      final repository = _MockGameCollectionRepository();
      when(() => repository.removalMark()).thenAnswer((_) async => 0);
      when(
        () => repository.mergeFromServer(
          any(),
          removalsSince: any(named: 'removalsSince'),
        ),
      ).thenAnswer((_) async {});
      container.registerSingleton<GameCollectionRepository>(repository);
    }
    if (games) {
      final repository = _MockGameRepository();
      when(() => repository.cachePlatformGameSummaries(any()))
          .thenAnswer((_) async {});
      container.registerSingleton<GameRepository>(repository);
    }
    if (client) {
      container.registerSingleton<GameCollectionRemoteDataSource>(remote);
    }
  }

  Future<void> install({DateTime Function()? now}) =>
      GameCollectionHydrateInstaller(now: now)
          .install(container, _server, 'user-1');

  test('install starts the hydrate', () async {
    register();
    await install();
    // The hydrate is unawaited, so let its first turn run.
    await Future<void>.delayed(Duration.zero);

    expect(remote.requests.length, 1);
  });

  test('install does not wait for the hydrate to finish', () async {
    // Activation is the bootstrap gate: awaiting the network here would put
    // it on the sign-in path.
    register();
    final blocked = Completer<PaginatedResult<GameCollectionWithSummary>>();
    remote.respond = (_) => blocked.future;

    await install().timeout(const Duration(seconds: 1));

    expect(blocked.isCompleted, isFalse);
    blocked.complete(_empty());
  });

  test('install completes when the hydrate fails', () async {
    // A throw out of install() aborts activation, which signs the user out.
    register();
    remote.respond = (_) => _offline();

    await install();
    await Future<void>.delayed(Duration.zero);

    expect(remote.requests.length, 1);
  });

  group('a missing collaborator is a no-op, not a sign-out', () {
    for (final (label, registerAllBut) in <(String, void Function())>[
      ('the collection client', () => register(client: false)),
      ('the collection repository', () => register(collection: false)),
      ('the game repository', () => register(games: false)),
    ]) {
      test('without $label', () async {
        registerAllBut();

        await install();
        await Future<void>.delayed(Duration.zero);

        expect(remote.requests.length, 0);
        // An absent status reads as idle, and an absent refresher as no
        // retry to offer. A registered one would claim a hydrate that
        // cannot run.
        expect(
          container.isRegistered<GameCollectionHydrationStatus>(),
          isFalse,
        );
        expect(container.isRegistered<GameCollectionRefresher>(), isFalse);
      });
    }
  });

  group('hydration status (#44)', () {
    test('reads running before install returns, then refreshed', () async {
      register();
      final blocked = Completer<PaginatedResult<GameCollectionWithSummary>>();
      remote.respond = (_) => blocked.future;

      await install();
      final status = container.get<GameCollectionHydrationStatus>();

      // Before the drain's first turn: the list can be built in that window,
      // and an idle status there would say the collection is empty while
      // the cache is about to fill.
      expect(status.state, GameCollectionHydrationState.running);

      blocked.complete(_empty());
      await Future<void>.delayed(Duration.zero);

      expect(status.state, GameCollectionHydrationState.refreshed);
    });

    test('reports a failed pass as failed', () async {
      register();
      remote.respond = (_) => _offline();

      await install();
      await Future<void>.delayed(Duration.zero);

      expect(
        container.get<GameCollectionHydrationStatus>().state,
        GameCollectionHydrationState.failed,
      );
    });

    test('a pass landing after the scope pops does not throw', () async {
      // The drain is unawaited, so it outlives the scope that started it.
      register();
      final blocked = Completer<PaginatedResult<GameCollectionWithSummary>>();
      remote.respond = (_) => blocked.future;
      await install();
      final status = container.get<GameCollectionHydrationStatus>();

      await container.dispose();
      blocked.complete(_empty());
      await Future<void>.delayed(Duration.zero);

      // Closed by the teardown, so the late outcome is dropped.
      expect(status.state, GameCollectionHydrationState.running);
    });
  });

  group('the retry the list calls (#44)', () {
    test('runs a pass inside the window, where a trigger would not', () async {
      register();
      await install();
      await Future<void>.delayed(Duration.zero);

      await container.get<GameCollectionRefresher>().refresh();

      // Once at install, once for the press: someone asked.
      expect(remote.requests.length, 2);
    });

    test('drives the status the list already watches', () async {
      register();
      remote.respond = (_) => _offline();
      await install();
      await Future<void>.delayed(Duration.zero);
      final seen = <GameCollectionHydrationState>[];
      final watching = container
          .get<GameCollectionHydrationStatus>()
          .watch()
          .map((h) => h.state)
          .listen(seen.add);
      addTearDown(watching.cancel);

      remote.respond = (_) => _empty();
      await container.get<GameCollectionRefresher>().refresh();
      await Future<void>.delayed(Duration.zero);

      expect(seen, [
        GameCollectionHydrationState.failed,
        GameCollectionHydrationState.running,
        GameCollectionHydrationState.refreshed,
      ]);
    });

    test('a press during the install-time pass joins it', () async {
      register();
      final blocked = Completer<PaginatedResult<GameCollectionWithSummary>>();
      remote.respond = (_) => blocked.future;
      await install();

      final retry = container.get<GameCollectionRefresher>().refresh();
      blocked.complete(_empty());
      await retry;

      expect(remote.requests.length, 1);
      expect(
        container.get<GameCollectionHydrationStatus>().state,
        GameCollectionHydrationState.refreshed,
      );
    });
  });

  group('re-hydrate registration', () {
    Future<SessionRehydrator> withRehydrator({bool client = true}) async {
      register(client: client);
      await const SessionRehydratorInstaller().install(
        container,
        _server,
        'user-1',
      );
      return container.get<SessionRehydrator>();
    }

    test('a failed pass is re-run by a later trigger', () async {
      final rehydrator = await withRehydrator();
      remote.respond = (_) => _offline();
      await install();
      await Future<void>.delayed(Duration.zero);

      // The server comes back.
      remote.respond = (_) => _empty();
      await rehydrator.rehydrateStale();

      expect(remote.requests.length, 2);
    });

    group('a completed pass', () {
      const window = GameCollectionHydrateInstaller.staleAfter;
      late DateTime clock;

      setUp(() => clock = DateTime.utc(2026, 9, 26, 12));

      Future<SessionRehydrator> completed() async {
        final rehydrator = await withRehydrator();
        await install(now: () => clock);
        await Future<void>.delayed(Duration.zero);
        return rehydrator;
      }

      test('is not re-run inside the window', () async {
        final rehydrator = await completed();

        clock = clock.add(window - const Duration(seconds: 1));
        await rehydrator.rehydrateStale();

        expect(remote.requests.length, 1);
      });

      // A session left running would otherwise never see another device's
      // changes, which #300 fixed for households.
      test('is re-run once the window has passed', () async {
        final rehydrator = await completed();

        clock = clock.add(window);
        await rehydrator.rehydrateStale();

        expect(remote.requests.length, 2);
      });

      test('a failed re-run is re-run by the next trigger', () async {
        final rehydrator = await completed();
        clock = clock.add(window);
        remote.respond = (_) => _offline();
        await rehydrator.rehydrateStale();

        remote.respond = (_) => _empty();
        await rehydrator.rehydrateStale();

        expect(remote.requests.length, 3);
      });
    });

    test('a trigger arriving during the install-time pass adds no second '
        'request', () async {
      final rehydrator = await withRehydrator();
      final blocked = Completer<PaginatedResult<GameCollectionWithSummary>>();
      remote.respond = (_) => blocked.future;
      await install();

      await rehydrator.rehydrateStale();
      blocked.complete(_empty());
      await Future<void>.delayed(Duration.zero);

      expect(remote.requests.length, 1);
    });

    test('registers nothing where there is no collection client', () async {
      final rehydrator = await withRehydrator(client: false);

      await install();
      // A registered entry would be stale (it never ran) and would resolve
      // the missing client here.
      await rehydrator.rehydrateStale();

      expect(remote.requests.length, 0);
    });
  });

  // #432: on web another tab can move the shared session cookie to another
  // user while this scope still belongs to the first. A pass sent then would
  // read the other user's collection.
  group('the session identity check', () {
    test('asks about the scope user before a pass', () async {
      register();
      final guard = _FakeIdentityGuard(answer: SessionConfirmation.confirmed);
      container.registerSingleton<SessionIdentityGuard>(guard);

      await install();
      await pumpEventQueue();

      expect(guard.askedFor, ['user-1']);
      expect(remote.requests.length, 1);
    });

    test('a pass it refuses sends nothing, and reads as failed so a later '
        'trigger tries again', () async {
      register();
      container.registerSingleton<SessionIdentityGuard>(
        _FakeIdentityGuard(answer: SessionConfirmation.notThisUser),
      );

      await install();
      await pumpEventQueue();

      expect(remote.requests.length, 0);
      expect(
        container.get<GameCollectionHydrationStatus>().state,
        GameCollectionHydrationState.failed,
      );
    });
  });
}
