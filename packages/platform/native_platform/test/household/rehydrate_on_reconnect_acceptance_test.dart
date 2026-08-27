import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:di/di.dart';
import 'package:flutter/widgets.dart' hide ConnectionState;
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:native_platform/native_platform.dart';
import 'package:network_interface/network_interface.dart';

/// The scenario #302 was filed from, end to end across every seam it
/// touches: the session installers, the registry, the shell trigger and
/// the household drain.
///
/// The app starts while the server is unreachable. Sign-in succeeds
/// against stored credentials — offline-first working as designed — the
/// session activates, the install-time drain fails, and the list says it
/// could not refresh. The server comes back. Before #302 nothing noticed
/// for the life of that session; the only route back online was signing
/// out and in.
///
/// The trigger driven here is a connectivity edge, which is *not* what the
/// filed run itself would produce (a server restarting leaves the device's
/// transport up throughout — see #311). It is the trigger this issue
/// ships, and the chain it exercises is the same one #300 and #311 drive.
class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockHouseholdRemoteDataSource extends Mock
    implements HouseholdRemoteDataSource {}

class _FakeActiveServerScope implements ActiveServerScope {
  _FakeActiveServerScope(this._active);
  final ActiveServer _active;

  @override
  ActiveServer? get active => _active;

  @override
  Stream<ActiveServer?> watchActive() => Stream<ActiveServer?>.value(_active);
}

class _FakeConnectivityService implements ConnectivityService {
  final _changes = StreamController<ConnectivityState>.broadcast();
  ConnectivityState _current = ConnectivityState.online;

  @override
  ConnectivityState get current => _current;

  @override
  Stream<ConnectivityState> watch() async* {
    yield _current;
    yield* _changes.stream;
  }

  void emit(ConnectivityState state) {
    _current = state;
    _changes.add(state);
  }

  Future<void> dispose() => _changes.close();
}

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

PaginatedResult<HouseholdWithMembers> _page(List<String> ids) =>
    PaginatedResult(
      items: [
        for (final id in ids)
          (
            household: Household(
              id: id,
              name: 'Household $id',
              createdAt: DateTime.utc(2024),
              updatedAt: DateTime.utc(2024),
            ),
            members: const <HouseholdMember>[],
          ),
      ],
      meta: PaginationMeta(
        page: 1,
        limit: 100,
        total: ids.length,
        totalPages: 1,
        hasMore: false,
      ),
    );

void main() {
  late DependencyContainerImpl container;
  late _MockHouseholdRepository repo;
  late _MockHouseholdRemoteDataSource remote;
  late _FakeConnectivityService connectivity;
  late ActiveServerScope scope;

  setUp(() {
    container = DependencyContainerImpl();
    repo = _MockHouseholdRepository();
    remote = _MockHouseholdRemoteDataSource();
    connectivity = _FakeConnectivityService();
    container
      ..registerSingleton<HouseholdRepository>(repo)
      ..registerSingleton<HouseholdRemoteDataSource>(remote);
    when(() => repo.cacheHousehold(any())).thenAnswer((_) async {});
    when(() => repo.cacheMembers(any())).thenAnswer((_) async {});
    // The shell reads the container off the active server, as it does in
    // production, rather than being handed one directly.
    scope = _FakeActiveServerScope(
      ActiveServer(
        serverId: 'server-1',
        displayName: 'My Server',
        identity: _config().cachedIdentity,
        container: container,
      ),
    );
  });

  setUpAll(() {
    registerFallbackValue(
      Household(
        id: 'fallback',
        name: 'fallback',
        createdAt: DateTime.utc(2024),
        updatedAt: DateTime.utc(2024),
      ),
    );
  });

  tearDown(() async {
    await connectivity.dispose();
    await container.dispose();
  });

  /// Runs the user-scope installers this composition ships, in the order
  /// `buildNativeUserScopeInstallers` puts them in, minus the storage one
  /// whose registrations are stubbed above.
  ///
  /// The pump at the end is what lets the install-time drain finish: it is
  /// started unawaited (#267 D2), and a widget test's clock is fake, so
  /// awaiting a real delay here would simply never return.
  Future<void> activateSession(WidgetTester tester) async {
    await const SessionRehydratorInstaller().install(
      container,
      _config(),
      'user-1',
    );
    await const HouseholdHydrateInstaller().install(
      container,
      _config(),
      'user-1',
    );
    await tester.pump();
  }

  testWidgets('a session that started against a down server refreshes when '
      'connectivity returns', (tester) async {
    when(
      () => remote.fetchHouseholds(
        page: any(named: 'page'),
        limit: any(named: 'limit'),
      ),
    ).thenThrow(
      const HouseholdRemoteTransientException('offline', statusCode: 503),
    );

    await activateSession(tester);
    final status = container.get<HouseholdHydrationStatus>();

    // Where #302 starts: the list is showing "couldn't refresh", and
    // nothing in the client will ever ask again on its own.
    expect(status.state, equals(HouseholdHydrationState.failed));
    verifyNever(() => repo.cacheHousehold(any()));

    await tester.pumpWidget(
      SessionRehydrateTrigger(
        scopeSource: () => scope,
        connectivity: connectivity,
        child: const SizedBox.shrink(),
      ),
    );

    // The server comes back.
    reset(remote);
    when(
      () => remote.fetchHouseholds(
        page: any(named: 'page'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => _page(['h-1']));

    connectivity.emit(ConnectivityState.offline);
    await tester.pump();
    connectivity.emit(ConnectivityState.online);
    await tester.pumpAndSettle();

    verify(() => remote.fetchHouseholds(page: 1, limit: 100)).called(1);
    verify(() => repo.cacheHousehold(any())).called(1);
    expect(status.state, equals(HouseholdHydrationState.refreshed));
  });

  testWidgets('a session whose first pass succeeded is left alone', (
    tester,
  ) async {
    when(
      () => remote.fetchHouseholds(
        page: any(named: 'page'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) async => _page(['h-1']));

    await activateSession(tester);
    expect(
      container.get<HouseholdHydrationStatus>().state,
      equals(HouseholdHydrationState.refreshed),
    );

    await tester.pumpWidget(
      SessionRehydrateTrigger(
        scopeSource: () => scope,
        connectivity: connectivity,
        child: const SizedBox.shrink(),
      ),
    );
    reset(remote);

    connectivity.emit(ConnectivityState.offline);
    await tester.pump();
    connectivity.emit(ConnectivityState.online);
    await tester.pumpAndSettle();

    verifyNever(
      () => remote.fetchHouseholds(
        page: any(named: 'page'),
        limit: any(named: 'limit'),
      ),
    );
  });

  testWidgets('an edge after the session ends re-runs nothing', (tester) async {
    when(
      () => remote.fetchHouseholds(
        page: any(named: 'page'),
        limit: any(named: 'limit'),
      ),
    ).thenThrow(
      const HouseholdRemoteTransientException('offline', statusCode: 503),
    );

    await activateSession(tester);
    await tester.pumpWidget(
      SessionRehydrateTrigger(
        scopeSource: () => scope,
        connectivity: connectivity,
        child: const SizedBox.shrink(),
      ),
    );

    // Sign-out: the user-session scope is disposed, which closes the
    // registry with it.
    await container.dispose();
    reset(remote);

    connectivity.emit(ConnectivityState.offline);
    await tester.pump();
    connectivity.emit(ConnectivityState.online);
    await tester.pumpAndSettle();

    verifyNever(
      () => remote.fetchHouseholds(
        page: any(named: 'page'),
        limit: any(named: 'limit'),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
