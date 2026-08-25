import 'dart:async';

import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
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
}
