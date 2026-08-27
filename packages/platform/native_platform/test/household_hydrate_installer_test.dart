import 'dart:async';

import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:native_platform/native_platform.dart';
import 'package:network_interface/network_interface.dart';

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockHouseholdRemoteDataSource extends Mock
    implements HouseholdRemoteDataSource {}

const _kAuthBase = 'https://api.example.test/api/auth';

ServerConfig _config() => ServerConfig(
  id: 'local-1',
  displayName: 'My Server',
  serverUrl: 'https://api.example.test',
  connectionState: ConnectionState.active,
  bgeServerId: 'server-1',
  cachedIdentity: ServerIdentity(
    serverId: 'server-1',
    issuer: 'https://api.example.test',
    wellKnownSchemaVersion: 1,
    name: 'Test BGE Server',
    deviceAuthorizationEndpoint: '$_kAuthBase/device',
    authBasePath: _kAuthBase,
    sessionEndpoint: '$_kAuthBase/get-session',
    signOutEndpoint: '$_kAuthBase/sign-out',
    passkeySupported: false,
    twoFactorSupported: false,
    anonymousAuthSupported: false,
    strategies: const [
      EmailAndPasswordStrategy(
        signUpDisabled: false,
        signInEndpoint: '$_kAuthBase/sign-in/email',
        signUpEndpoint: '$_kAuthBase/sign-up/email',
      ),
    ],
  ),
  lastIdentityFetchedAt: DateTime.utc(2024),
);

PaginatedResult<HouseholdWithMembers> _emptyPage() => PaginatedResult(
  items: const [],
  meta: const PaginationMeta(
    page: 1,
    limit: 100,
    total: 0,
    totalPages: 0,
    hasMore: false,
  ),
);

void main() {
  late DependencyContainerImpl container;
  late _MockHouseholdRepository repo;
  late _MockHouseholdRemoteDataSource remote;

  setUp(() {
    container = DependencyContainerImpl();
    repo = _MockHouseholdRepository();
    remote = _MockHouseholdRemoteDataSource();
    container.registerSingleton<HouseholdRepository>(repo);
    container.registerSingleton<HouseholdRemoteDataSource>(remote);
  });

  tearDown(() async => container.dispose());

  test('the hydrate installer runs after the one registering the repository '
      'it resolves', () {
    final installers = buildNativeUserScopeInstallers();

    final storage = installers.indexWhere(
      (i) => i is UserSessionScopeInstaller,
    );
    final hydrate = installers.indexWhere(
      (i) => i is HouseholdHydrateInstaller,
    );

    // Installers run in list order and may resolve what a predecessor
    // registered. HouseholdRepository is registered by the storage
    // installer, so ordering here is a real constraint, not cosmetics.
    expect(storage, isNonNegative);
    expect(hydrate, greaterThan(storage));
  });

  test('install starts the drain', () async {
    when(
      () => remote.fetchHouseholds(
        page: any(named: 'page'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => _emptyPage());

    await const HouseholdHydrateInstaller().install(
      container,
      _config(),
      'user-1',
    );
    // The drain is unawaited, so let its first turn run.
    await Future<void>.delayed(Duration.zero);

    verify(() => remote.fetchHouseholds(page: 1, limit: 100)).called(1);
  });

  test('install does not wait for the drain to finish', () async {
    // THE decision that matters (#267 D2). Scope activation is the
    // bootstrap gate: awaiting a slow or hanging fetch here would stall
    // sign-in behind the network.
    final blocked = Completer<PaginatedResult<HouseholdWithMembers>>();
    when(
      () => remote.fetchHouseholds(
        page: any(named: 'page'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) => blocked.future);

    await const HouseholdHydrateInstaller()
        .install(container, _config(), 'user-1')
        .timeout(const Duration(seconds: 1));

    expect(blocked.isCompleted, isFalse);
    blocked.complete(_emptyPage());
  });

  test('install completes when the drain fails', () async {
    // A throw out of install() aborts scope activation, and the shell
    // responds by signing the user out. An unreachable server must not do
    // that.
    when(
      () => remote.fetchHouseholds(
        page: any(named: 'page'),
        limit: any(named: 'limit'),
      ),
    ).thenThrow(
      const HouseholdRemoteTransientException('offline', statusCode: 503),
    );

    await expectLater(
      const HouseholdHydrateInstaller().install(container, _config(), 'user-1'),
      completes,
    );
    await Future<void>.delayed(Duration.zero);
  });

  group('hydration status (#269 D1)', () {
    test('install publishes a status the list screen can read', () async {
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => _emptyPage());

      await const HouseholdHydrateInstaller().install(
        container,
        _config(),
        'user-1',
      );

      expect(container.isRegistered<HouseholdHydrationStatus>(), isTrue);
    });

    test('reports the pass as running, then refreshed', () async {
      final blocked = Completer<PaginatedResult<HouseholdWithMembers>>();
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) => blocked.future);

      await const HouseholdHydrateInstaller().install(
        container,
        _config(),
        'user-1',
      );
      final status = container.get<HouseholdHydrationStatus>();

      // Set synchronously during install, not on the drain's first turn:
      // the screen can be built before the fetch has been issued, and an
      // idle status there would render "no households" over a cache that
      // is about to fill.
      expect(status.state, equals(HouseholdHydrationState.running));

      blocked.complete(_emptyPage());
      await Future<void>.delayed(Duration.zero);

      expect(status.state, equals(HouseholdHydrationState.refreshed));
    });

    test('reports a failed drain as failed', () async {
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenThrow(
        const HouseholdRemoteTransientException('offline', statusCode: 503),
      );

      await const HouseholdHydrateInstaller().install(
        container,
        _config(),
        'user-1',
      );
      await Future<void>.delayed(Duration.zero);

      expect(
        container.get<HouseholdHydrationStatus>().state,
        equals(HouseholdHydrationState.failed),
      );
    });

    test('publishes no status where there is no household client', () async {
      // Absent reads as idle (#269 D1). Registering a permanently-idle
      // status instead would be a lie the screen cannot see through.
      final bare = DependencyContainerImpl()
        ..registerSingleton<HouseholdRepository>(repo);
      addTearDown(bare.dispose);

      await const HouseholdHydrateInstaller().install(
        bare,
        _config(),
        'user-1',
      );

      expect(bare.isRegistered<HouseholdHydrationStatus>(), isFalse);
    });

    test('a drain landing after the scope pops does not throw', () async {
      // The drain is unawaited, so it outlives the scope that started it.
      // The status is closed by then, and an error out of this path is an
      // unhandled async error on the sign-in path.
      final blocked = Completer<PaginatedResult<HouseholdWithMembers>>();
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) => blocked.future);

      await const HouseholdHydrateInstaller().install(
        container,
        _config(),
        'user-1',
      );
      final status = container.get<HouseholdHydrationStatus>();

      await container.dispose();
      blocked.complete(_emptyPage());
      await Future<void>.delayed(Duration.zero);

      // Closed by the scope teardown, so the late outcome is dropped.
      expect(status.state, equals(HouseholdHydrationState.running));
    });
  });

  test('install is a no-op where the server has no household client', () async {
    // Web registers no HouseholdRemoteDataSource (#137). Resolving an
    // unregistered type throws, which here would mean an unrecoverable
    // sign-in.
    final bare = DependencyContainerImpl()
      ..registerSingleton<HouseholdRepository>(repo);
    addTearDown(bare.dispose);

    await expectLater(
      const HouseholdHydrateInstaller().install(bare, _config(), 'user-1'),
      completes,
    );
  });

  group('re-hydrate registration (#302 D2, D4)', () {
    /// A container carrying the session rehydrator the leading installer
    /// registers in production.
    Future<SessionRehydrator> withRehydrator() async {
      await const SessionRehydratorInstaller().install(
        container,
        _config(),
        'user-1',
      );
      return container.get<SessionRehydrator>();
    }

    test('a failed pass is re-run by a later trigger', () async {
      final rehydrator = await withRehydrator();
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenThrow(
        const HouseholdRemoteTransientException('offline', statusCode: 503),
      );

      await const HouseholdHydrateInstaller().install(
        container,
        _config(),
        'user-1',
      );
      await Future<void>.delayed(Duration.zero);

      // The server comes back.
      reset(remote);
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => _emptyPage());

      await rehydrator.rehydrateStale();

      verify(() => remote.fetchHouseholds(page: 1, limit: 100)).called(1);
    });

    test(
      'the re-run drives the same status the screen is already watching',
      () async {
        final rehydrator = await withRehydrator();
        when(
          () => remote.fetchHouseholds(
            page: any(named: 'page'),
            limit: any(named: 'limit'),
          ),
        ).thenThrow(
          const HouseholdRemoteTransientException('offline', statusCode: 503),
        );

        await const HouseholdHydrateInstaller().install(
          container,
          _config(),
          'user-1',
        );
        await Future<void>.delayed(Duration.zero);
        final status = container.get<HouseholdHydrationStatus>();
        expect(status.state, equals(HouseholdHydrationState.failed));

        final seen = <HouseholdHydrationState>[];
        final subscription = status.watch().listen(seen.add);
        addTearDown(subscription.cancel);

        reset(remote);
        when(
          () => remote.fetchHouseholds(
            page: any(named: 'page'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) async => _emptyPage());
        await rehydrator.rehydrateStale();
        await Future<void>.delayed(Duration.zero);

        expect(status.state, equals(HouseholdHydrationState.refreshed));
        // The banner clears because the same holder moved, with no second
        // status and nothing for the screen to re-subscribe to (#270 D5).
        expect(
          seen,
          containsAllInOrder(<HouseholdHydrationState>[
            HouseholdHydrationState.failed,
            HouseholdHydrationState.running,
            HouseholdHydrationState.refreshed,
          ]),
        );
      },
    );

    test('a pass that succeeded inside the window is not stale, so a trigger '
        'leaves it alone', () async {
      final rehydrator = await withRehydrator();
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => _emptyPage());

      await const HouseholdHydrateInstaller().install(
        container,
        _config(),
        'user-1',
      );
      await Future<void>.delayed(Duration.zero);
      reset(remote);

      await rehydrator.rehydrateStale();

      verifyNever(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      );
    });

    test('a trigger arriving during the install-time pass adds no second '
        'drain', () async {
      // Pinned here at the seam that actually decides it: `running` is not
      // stale (#302 D4), so the entry is skipped and the trigger is
      // dropped rather than joined. The hydrator's own single-flight
      // (#302 D3) is the backstop for callers that do reach it, and is
      // pinned in the household package's hydrator tests.
      final rehydrator = await withRehydrator();
      final blocked = Completer<PaginatedResult<HouseholdWithMembers>>();
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) => blocked.future);

      await const HouseholdHydrateInstaller().install(
        container,
        _config(),
        'user-1',
      );
      // The install-time pass is unawaited and still in flight — the exact
      // overlap #300 could not settle on its own.
      final triggered = rehydrator.rehydrateStale();
      blocked.complete(_emptyPage());
      await triggered;
      await Future<void>.delayed(Duration.zero);

      verify(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).called(1);
    });

    test(
      'a composition with no rehydrator still installs and drains',
      () async {
        // Nothing registers the seam on web (#137), and shell tests compose
        // containers without it. A throw here would sign the user out.
        when(
          () => remote.fetchHouseholds(
            page: any(named: 'page'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) async => _emptyPage());

        await expectLater(
          const HouseholdHydrateInstaller().install(
            container,
            _config(),
            'user-1',
          ),
          completes,
        );
        await Future<void>.delayed(Duration.zero);

        verify(() => remote.fetchHouseholds(page: 1, limit: 100)).called(1);
      },
    );

    test('registers nothing where there is no household client', () async {
      final bare = DependencyContainerImpl()
        ..registerSingleton<HouseholdRepository>(repo);
      addTearDown(bare.dispose);
      await const SessionRehydratorInstaller().install(
        bare,
        _config(),
        'user-1',
      );

      await const HouseholdHydrateInstaller().install(
        bare,
        _config(),
        'user-1',
      );
      await bare.get<SessionRehydrator>().rehydrateStale();

      verifyNever(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      );
    });

    test('the rehydrator installer runs before the hydrate that registers '
        'with it', () {
      final installers = buildNativeUserScopeInstallers();

      final rehydrator = installers.indexWhere(
        (i) => i is SessionRehydratorInstaller,
      );
      final hydrate = installers.indexWhere(
        (i) => i is HouseholdHydrateInstaller,
      );

      expect(rehydrator, isNonNegative);
      expect(hydrate, greaterThan(rehydrator));
    });
  });

  group('the retry the screens call (#300 D5)', () {
    test('registers a refresher that re-runs the drain', () async {
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => _emptyPage());

      await const HouseholdHydrateInstaller().install(
        container,
        _config(),
        'user-1',
      );
      await Future<void>.delayed(Duration.zero);
      expect(container.isRegistered<HouseholdRefresher>(), isTrue);

      await container.get<HouseholdRefresher>().refresh();

      // Once at install, once for the retry: unlike a #302 trigger, a
      // press is not filtered by staleness — the user asked.
      verify(() => remote.fetchHouseholds(page: 1, limit: 100)).called(2);
    });

    test('a retry drives the status the screens already watch', () async {
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenThrow(
        const HouseholdRemoteTransientException('offline', statusCode: 503),
      );

      await const HouseholdHydrateInstaller().install(
        container,
        _config(),
        'user-1',
      );
      await Future<void>.delayed(Duration.zero);

      final status = container.get<HouseholdHydrationStatus>();
      expect(status.state, HouseholdHydrationState.failed);

      final seen = <HouseholdHydrationState>[];
      final watching = status.watch().listen(seen.add);
      addTearDown(watching.cancel);

      reset(remote);
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => _emptyPage());

      await container.get<HouseholdRefresher>().refresh();
      await Future<void>.delayed(Duration.zero);

      // The retry is not a second status: the banner the screens are
      // already watching is what clears (#302 D2's reasoning, and #270 D5).
      expect(seen, [
        HouseholdHydrationState.failed,
        HouseholdHydrationState.running,
        HouseholdHydrationState.refreshed,
      ]);
    });

    test('registers nothing where there is no household client', () async {
      // Web until #137, and shell tests: the screens read an absent
      // refresher as "no retry to offer" and render a banner without one.
      final bare = DependencyContainerImpl()
        ..registerSingleton<HouseholdRepository>(repo);
      addTearDown(bare.dispose);

      await const HouseholdHydrateInstaller().install(
        bare,
        _config(),
        'user-1',
      );

      expect(bare.isRegistered<HouseholdRefresher>(), isFalse);
    });

    test(
      'a retry racing the install-time pass drains once (#302 D3)',
      () async {
        // The re-entrancy question #300 asked to have recorded rather than
        // assumed. It is answered by the hydrator's single-flight, and this
        // is the household-side proof of it: the install-time pass is still
        // in flight when the retry arrives.
        final firstPage = Completer<PaginatedResult<HouseholdWithMembers>>();
        var calls = 0;
        when(
          () => remote.fetchHouseholds(
            page: any(named: 'page'),
            limit: any(named: 'limit'),
          ),
        ).thenAnswer((_) {
          calls++;
          return firstPage.future;
        });

        await const HouseholdHydrateInstaller().install(
          container,
          _config(),
          'user-1',
        );

        final retry = container.get<HouseholdRefresher>().refresh();
        firstPage.complete(_emptyPage());
        await retry;

        expect(calls, 1);
        expect(
          container.get<HouseholdHydrationStatus>().state,
          HouseholdHydrationState.refreshed,
        );
      },
    );
  });

  group('the staleness window (#300 D1, D2, D8, D15)', () {
    /// A container carrying the session rehydrator, as in production.
    Future<SessionRehydrator> withRehydrator() async {
      await const SessionRehydratorInstaller().install(
        container,
        _config(),
        'user-1',
      );
      return container.get<SessionRehydrator>();
    }

    late DateTime clock;

    setUp(() => clock = DateTime.utc(2026, 8, 27, 12));

    /// Installs with a clock the test drives, so a five-minute window does
    /// not cost five real minutes.
    Future<void> installAt() => HouseholdHydrateInstaller(
      now: () => clock,
    ).install(container, _config(), 'user-1');

    void answerWithEmptyPage() {
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenAnswer((_) async => _emptyPage());
    }

    void verifyDrained({required bool expected}) {
      Future<PaginatedResult<HouseholdWithMembers>> call() =>
          remote.fetchHouseholds(
            page: any(named: 'page'),
            limit: any(named: 'limit'),
          );
      expected ? verify(call).called(1) : verifyNever(call);
    }

    test('the window is the five minutes D2 recorded', () {
      // Pinned so the figure is a decision someone can argue with rather
      // than a constant to reverse-engineer. D2 recorded it as a guess.
      expect(
        HouseholdHydrateInstaller.staleAfter,
        equals(const Duration(minutes: 5)),
      );
    });

    test('a success older than the window is stale again', () async {
      final rehydrator = await withRehydrator();
      answerWithEmptyPage();

      await installAt();
      await Future<void>.delayed(Duration.zero);
      reset(remote);
      answerWithEmptyPage();

      clock = clock.add(
        HouseholdHydrateInstaller.staleAfter + const Duration(seconds: 1),
      );
      await rehydrator.rehydrateStale();
      await Future<void>.delayed(Duration.zero);

      verifyDrained(expected: true);
    });

    test('a success exactly at the window has aged out', () async {
      // The boundary is inclusive: at five minutes the answer is five
      // minutes old, which is what "longer ago than the window" was for.
      final rehydrator = await withRehydrator();
      answerWithEmptyPage();

      await installAt();
      await Future<void>.delayed(Duration.zero);
      reset(remote);
      answerWithEmptyPage();

      clock = clock.add(HouseholdHydrateInstaller.staleAfter);
      await rehydrator.rehydrateStale();
      await Future<void>.delayed(Duration.zero);

      verifyDrained(expected: true);
    });

    test('a create clears the window, so the next trigger drains '
        'inside it (#300 D9)', () async {
      final rehydrator = await withRehydrator();
      answerWithEmptyPage();

      await installAt();
      await Future<void>.delayed(Duration.zero);
      reset(remote);
      answerWithEmptyPage();

      // No clock advance at all: the create is what makes the set stale,
      // not elapsed time.
      container.get<HouseholdHydrationStatus>().markStale();
      await rehydrator.rehydrateStale();
      await Future<void>.delayed(Duration.zero);

      verifyDrained(expected: true);
    });

    test('a retry that fails inside the window leaves the next trigger '
        'stale', () async {
      // The one path that reaches `failed` with a *young* stamp: the manual
      // retry (#300 D5) runs whatever the window says, so a press a minute
      // after a success can fail with the successful pass's timestamp still
      // well inside the window. The status keeps that stamp on purpose --
      // the rows on screen are that old -- so what has to make this stale
      // is the state arm, not the age.
      final rehydrator = await withRehydrator();
      answerWithEmptyPage();

      await installAt();
      await Future<void>.delayed(Duration.zero);

      reset(remote);
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenThrow(
        const HouseholdRemoteTransientException('offline', statusCode: 503),
      );
      clock = clock.add(const Duration(minutes: 1));
      await container.get<HouseholdRefresher>().refresh();

      expect(
        container.get<HouseholdHydrationStatus>().state,
        HouseholdHydrationState.failed,
      );
      expect(
        container.get<HouseholdHydrationStatus>().sinceRefresh,
        equals(const Duration(minutes: 1)),
      );

      reset(remote);
      answerWithEmptyPage();
      await rehydrator.rehydrateStale();
      await Future<void>.delayed(Duration.zero);

      verifyDrained(expected: true);
    });

    test('a failed pass is stale regardless of the clock', () async {
      // `failed` is stale by state (#302 D4). The window only ever makes a
      // `refreshed` entry stale; it must not make a failed one fresh.
      final rehydrator = await withRehydrator();
      when(
        () => remote.fetchHouseholds(
          page: any(named: 'page'),
          limit: any(named: 'limit'),
        ),
      ).thenThrow(
        const HouseholdRemoteTransientException('offline', statusCode: 503),
      );

      await installAt();
      await Future<void>.delayed(Duration.zero);
      reset(remote);
      answerWithEmptyPage();

      await rehydrator.rehydrateStale();
      await Future<void>.delayed(Duration.zero);

      verifyDrained(expected: true);
    });
  });
}
