import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:app_shell/src/servers/servers_screen.dart';
import 'package:auth/auth.dart';
import 'package:bge_test_support/domain.dart';
import 'package:di/di.dart'
    show
        ContainerUserSessionScope,
        DependencyContainerImpl,
        UserScopeHost,
        VersionNegotiatorImpl,
        replayThenForward;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:go_router/go_router.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:network_interface/network_interface.dart';
import 'package:server_onboarding/server_onboarding.dart';
import 'package:ui/ui.dart' show BgeInlineBanner;

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';
import '../support/navigation.dart';
import '../support/server_list_fakes.dart';

/// The server the form finds at any address.
final ServerIdentity _betaIdentity = testServerIdentity().copyWith(
  serverId: 'bge-beta',
);

/// The id the fake orchestrator gives the server it adds.
const _betaId = 'local-bge-beta';

/// A server's count of changes made on this device that it hasn't had.
class _UnsentChanges implements UnsentChangesNoticeRepository {
  _UnsentChanges(this.count);

  final int count;

  @override
  Future<void> recordSessionStarted(String userId) async {}

  @override
  Future<void> recordSignedOut(String userId) async {}

  @override
  Future<int> unsentChangesCount() async => count;
}

/// A second server registered on the device.
const _gammaId = 'local-bge-gamma';

/// `Gamma`, registered beside `My Server` and not connected, signed in or
/// not as [repo] says. It offers no way in, so its sign-in screen tells
/// itself apart from `My Server`'s, which offers email and password.
ActiveServer _gamma(FakeAuthRepository repo) => ActiveServer(
  serverId: _gammaId,
  displayName: 'Gamma',
  identity: testServerIdentity().copyWith(
    serverId: 'bge-gamma',
    strategies: const [],
  ),
  container: buildActiveServer(repo, serverId: _gammaId).container,
);

/// A collection cache holding nothing, whose watch stays open, as Drift's
/// does. Each session has its own, so a page shows whose it was built for.
class _Collection implements GameCollectionRepository {
  @override
  Stream<List<GameCollectionListItem>> watchCollectionListItems() =>
      Stream.multi((stream) => stream.add(const []));

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// Registers [collection] for every session, as a server's user installers
/// register the session's caches.
class _CollectionInstaller implements UserScopeInstaller {
  _CollectionInstaller(this.collection);

  final GameCollectionRepository collection;

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async => container.registerSingleton<GameCollectionRepository>(collection);
}

/// A server's container with a user tier over it, as native's context has:
/// what a session registers resolves first, and goes when the session ends.
class _TieredContainer implements DependencyContainer {
  _TieredContainer(this._base, this._host);

  final DependencyContainer _base;
  final UserScopeHost _host;

  @override
  T get<T extends Object>() => _host.maybeGet<T>() ?? _base.get<T>();

  @override
  bool isRegistered<T extends Object>() =>
      _host.scopeHasRegistration<T>() || _base.isRegistered<T>();

  @override
  void registerSingleton<T extends Object>(
    T instance, {
    FutureOr<void> Function(T instance)? dispose,
  }) => _base.registerSingleton<T>(instance, dispose: dispose);

  @override
  void registerLazySingleton<T extends Object>(
    T Function() factory, {
    FutureOr<void> Function(T instance)? dispose,
  }) => _base.registerLazySingleton<T>(factory, dispose: dispose);

  @override
  void registerFactory<T extends Object>(T Function() factory) =>
      _base.registerFactory<T>(factory);

  @override
  Future<void> dispose() => _base.dispose();
}

/// A server whose collection lives in its user tier: there while its
/// `session` is open, gone once it ends.
typedef _TieredServer = ({
  ActiveServer server,
  ContainerUserSessionScope session,
  _Collection collection,
});

/// A session on a server, for the user [userId].
AuthResponse _sessionOf(String userId) =>
    testAuthResponse().copyWith.user(id: userId);

/// [name], whose id is [id], signed in or not as [auth] says, with a user
/// tier the shell opens as it signs in.
_TieredServer _tiered({
  required String id,
  required String name,
  required FakeAuthRepository auth,
}) {
  final base = DependencyContainerImpl();
  final host = UserScopeHost(parent: () => base);
  final collection = _Collection();
  final identity = testServerIdentity().copyWith(serverId: 'bge-$id');
  final session = ContainerUserSessionScope(
    host: host,
    installers: [_CollectionInstaller(collection)],
    server: ScopedServer.fromIdentity(identity),
  );
  final container = _TieredContainer(base, host)
    ..registerSingleton<AuthRepository>(auth)
    ..registerSingleton<UserSessionScope>(session);
  return (
    server: ActiveServer(
      serverId: id,
      displayName: name,
      identity: identity,
      container: container,
    ),
    session: session,
    collection: collection,
  );
}

/// A server's auth whose session check answers only once [_release] has.
class _HeldAuth extends FakeAuthRepository {
  _HeldAuth(this._release, {super.initialSession});

  final Future<void> _release;

  @override
  Future<AuthResponse?> getSession() async {
    await _release;
    return super.getSession();
  }
}

class _WellKnownClient implements WellKnownClient {
  @override
  Future<ServerIdentity> fetchIdentity(String serverUrl) async => _betaIdentity;
}

/// Online unless a test says otherwise.
class _Connectivity implements ConnectivityService {
  @override
  ConnectivityState current = ConnectivityState.online;

  @override
  Stream<ConnectivityState> watch() => Stream.value(ConnectivityState.online);
}

/// Finds a server among [_scope]'s by the id its identity names, as the
/// registry finds an added server (#82).
class _ScopeLookup implements KnownServerLookup {
  _ScopeLookup(this._scope);

  final _OrchestratorScope _scope;

  @override
  Future<String?> localServerIdFor(String bgeServerId) async {
    for (final server in _scope.servers.values) {
      if (server.identity.serverId == bgeServerId) return server.serverId;
    }
    return null;
  }
}

/// The active server as the orchestrator says it is, re-read on each of
/// its switches, as native's scope reads it. A server the orchestrator
/// makes active is one [servers] knows.
class _OrchestratorScope implements ActiveServerScope {
  _OrchestratorScope(this._orchestrator, ActiveServer first)
    : servers = {first.serverId: first};

  final FakeServerOrchestrator _orchestrator;
  final Map<String, ActiveServer> servers;

  @override
  ActiveServer? get active => servers[_orchestrator.activeServerId];

  @override
  Stream<ActiveServer?> watchActive() => replayThenForward(
    current: () => active,
    updates: () => _orchestrator.watchActiveContext().map((_) => active),
  );
}

/// Adding a server from the manager (#134): signed in or out, the app goes
/// to the new server's sign-in screen, and a server already added is
/// refused where it was typed. The sign-in screen opens the manager on
/// native, and names whichever server is active, however it became so.
void main() {
  late FakeServerOrchestrator orchestrator;
  late _OrchestratorScope scope;
  late _Connectivity connectivity;

  /// The auth of the server the last add added, signed out, as a new one
  /// is.
  late FakeAuthRepository addedAuth;

  /// The root container the add flow resolves its collaborators from.
  DependencyContainerImpl rootContainer() {
    connectivity = _Connectivity();
    final container = DependencyContainerImpl()
      ..registerLazySingleton<WellKnownClient>(_WellKnownClient.new)
      ..registerLazySingleton<VersionNegotiator>(VersionNegotiatorImpl.new)
      ..registerSingleton<ConnectivityService>(connectivity)
      ..registerSingleton<BuildInfo>(BuildInfo.unknown);
    container.registerLazySingleton<ServerOnboardingDeps>(
      () => ServerOnboardingDeps.from(container),
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Boots the app on one server, `My Server`, signed in or not as [repo]
  /// says, or on [first] where one is given. An added server is active and
  /// signed out, as a new one is.
  ///
  /// [others] are registered too, and not connected. [native] false boots
  /// as web does: no orchestrator and no registry. [unsentChanges] counts
  /// `My Server`'s changes that haven't reached it.
  ///
  /// [firstRun] boots with no server added, to the first-run add, and `My
  /// Server` is neither registered nor active. [holder] is the deep-link
  /// slot (#82), and links are looked up among the servers [scope] knows.
  Future<AppBootstrapCubit> pumpApp(
    WidgetTester tester,
    FakeAuthRepository repo, {
    ActiveServer? first,
    List<ActiveServer> others = const [],
    bool native = true,
    bool firstRun = false,
    UnsentChangesNoticeRepository? unsentChanges,
    PendingDeepLinkHolder? holder,
  }) async {
    orchestrator = FakeServerOrchestrator();
    addTearDown(orchestrator.close);
    final alpha =
        first ?? buildActiveServer(repo, unsentChangesNotice: unsentChanges);
    if (!firstRun) orchestrator.activate(alpha.serverId);
    scope = _OrchestratorScope(orchestrator, alpha);
    if (firstRun) scope.servers.clear();
    for (final other in others) {
      scope.servers[other.serverId] = other;
    }
    orchestrator.onAdd = (serverId, displayName) {
      addedAuth = FakeAuthRepository();
      final added = buildActiveServer(addedAuth, serverId: serverId);
      scope.servers[serverId] = ActiveServer(
        serverId: serverId,
        displayName: displayName,
        identity: _betaIdentity,
        container: added.container,
      );
    };
    final registered = FakeRegisteredServers([
      for (final server in [if (!firstRun) alpha, ...others])
        testRegisteredServer(server.serverId, server.displayName),
    ]);
    addTearDown(registered.close);

    final cubit = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(
        outcomes: [
          if (native)
            BootstrapResult(
              hasServer: !firstRun,
              activeServerScope: scope,
              orchestrator: orchestrator,
              registeredServers: registered,
              knownServerLookup: _ScopeLookup(scope),
            )
          else
            BootstrapResult(
              hasServer: true,
              activeServerScope: FakeActiveServerScope(alpha),
            ),
        ],
      ),
      hydratedStorageInitializer: (_) async {},
    );
    addTearDown(cubit.close);
    await tester.pumpWidget(
      BgeApp(
        bootstrapCubit: cubit,
        rootContainer: rootContainer(),
        pendingDeepLinkHolder: holder,
      ),
    );
    await cubit.initialize();
    await tester.pumpAndSettle();
    return cubit;
  }

  GoRouter routerOf(WidgetTester tester) =>
      tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
          as GoRouter;

  /// The sign-in screen's way to the manager.
  final manageServers = find.widgetWithText(TextButton, 'Manage servers');

  /// Opens the manager from the sign-in screen's **Manage servers**.
  Future<void> tapManageServers(WidgetTester tester) async {
    await tester.ensureVisible(manageServers);
    await tester.pumpAndSettle();
    await tester.tap(manageServers);
    await tester.pumpAndSettle();
    expect(routerOf(tester).state.uri.path, AppRoutes.servers);
    expect(find.byType(ServersScreen), findsOneWidget);
  }

  /// Opens the manager by its route, as the signed-in menu does.
  Future<void> pushManager(WidgetTester tester) async {
    unawaited(routerOf(tester).push<void>(AppRoutes.servers));
    await tester.pumpAndSettle();
    expect(find.byType(ServersScreen), findsOneWidget);
  }

  /// Opens the open manager's add page.
  Future<void> openAdd(WidgetTester tester) async {
    await tester.tap(find.byKey(ServersScreen.addKey));
    await tester.pumpAndSettle();
    expect(routerOf(tester).state.uri.path, AppRoutes.serversAdd);
    expect(find.byType(ServerAddScreen), findsOneWidget);
  }

  /// Adds the server at `bge.example.com`, nicknamed `Beta`.
  Future<void> submit(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(ServerAddForm.urlFieldKey),
      'bge.example.com',
    );
    await tester.enterText(find.byKey(ServerAddForm.aliasFieldKey), 'Beta');
    // reactive_forms delivers control changes asynchronously.
    await tester.pumpAndSettle();
    final button = find.byKey(ServerAddForm.submitButtonKey);
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  /// The sign-in screen showing is for [name], whose id is [serverId]:
  /// drawn and announced, with its own session underneath, and nothing
  /// anywhere still names `My Server`, the server the app booted on.
  void expectSignInFor(
    WidgetTester tester, {
    required String name,
    required String serverId,
  }) {
    expect(routerOf(tester).state.uri.path, AppRoutes.auth);
    expect(find.byType(AuthScreen), findsOneWidget);
    expect(scope.active?.displayName, name);
    final handle = tester.ensureSemantics();
    expect(
      find.descendant(of: find.byType(AuthScreen), matching: find.text(name)),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Server: $name'), findsOneWidget);
    expect(find.text('My Server', skipOffstage: false), findsNothing);
    handle.dispose();
    expect(find.byKey(ValueKey('auth_bloc_$serverId')), findsOneWidget);
  }

  /// The app is on the sign-in screen for `Beta`, the server just added,
  /// with nothing of the manager left to go Back to.
  Future<void> expectBetaSignIn(
    WidgetTester tester,
    AppBootstrapCubit cubit,
  ) async {
    expect(orchestrator.calls, ['add $_betaId']);
    expect(cubit.state, isA<AppBootstrapNeedsAuth>());
    // The signed-out flow's sign-in page was built before the add, for the
    // old server.
    expectSignInFor(tester, name: 'Beta', serverId: _betaId);
    expect(find.byType(ServerAddScreen, skipOffstage: false), findsNothing);
    expect(find.byType(ServersScreen, skipOffstage: false), findsNothing);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(routerOf(tester).state.uri.path, AppRoutes.auth);
    expect(find.byType(ServersScreen), findsNothing);
  }

  testWidgets('adding a server while signed in lands on its sign-in screen', (
    tester,
  ) async {
    final cubit = await pumpApp(
      tester,
      FakeAuthRepository(initialSession: testAuthResponse()),
    );
    expect(cubit.state, isA<AppBootstrapReady>());
    await pushManager(tester);
    await openAdd(tester);

    await submit(tester);

    await expectBetaSignIn(tester, cubit);
  });

  testWidgets('adding a server while signed out lands on its sign-in screen', (
    tester,
  ) async {
    final cubit = await pumpApp(tester, FakeAuthRepository());
    expect(cubit.state, isA<AppBootstrapNeedsAuth>());
    expect(routerOf(tester).state.uri.path, AppRoutes.auth);
    await tapManageServers(tester);
    await openAdd(tester);

    await submit(tester);

    await expectBetaSignIn(tester, cubit);
  });

  testWidgets('a server already added is refused inline', (tester) async {
    final cubit = await pumpApp(
      tester,
      FakeAuthRepository(initialSession: testAuthResponse()),
    );
    await pushManager(tester);
    await openAdd(tester);
    orchestrator.onAdd = (_, _) =>
        throw const DuplicateServerException.url('https://bge.example.com');

    await submit(tester);

    expect(
      find.text('That server is already registered on this device.'),
      findsOneWidget,
    );
    expect(routerOf(tester).state.uri.path, AppRoutes.serversAdd);
    expect(find.byType(ServerAddScreen), findsOneWidget);
    expect(cubit.state, isA<AppBootstrapReady>());
    expect(scope.active?.displayName, 'My Server');
  });

  group('adding the server a link names (#971)', () {
    /// A link for `bge-beta`, the server the form finds at any address,
    /// carrying its address.
    const betaLink = ServerDeepLink(
      serverId: 'bge-beta',
      location:
          '/server/bge-beta/event/ev-1?address=https%3A%2F%2Fbge.example.com',
    );

    /// [betaLink]'s address, as the add form shows it.
    const betaAddress = 'https://bge.example.com';

    PendingDeepLinkHolder buildHolder() {
      final holder = PendingDeepLinkHolder();
      addTearDown(holder.dispose);
      return holder;
    }

    /// What the add form's address field holds.
    String addressShown(WidgetTester tester) => tester
        .widget<TextField>(
          find.descendant(
            of: find.byKey(ServerAddForm.urlFieldKey),
            matching: find.byType(TextField),
          ),
        )
        .controller!
        .text;

    /// Submits the add form as it stands.
    Future<void> submitAsIs(WidgetTester tester) async {
      final button = find.byKey(ServerAddForm.submitButtonKey);
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    // Nothing is added, so there is no link to hand back, and the slot the
    // unknown-server screen emptied stays empty.
    for (final (name, banner, fail) in <(String, String, void Function())>[
      (
        'capacity',
        "You've reached the maximum number of connected servers on this "
            'device.',
        () =>
            orchestrator.onAdd = (_, _) =>
                throw const ServerCapacityExceededException(
                  currentConnected: 5,
                  maxCapacity: 5,
                ),
      ),
      (
        'duplicate',
        'That server is already registered on this device.',
        () => orchestrator.onAdd = (_, _) =>
            throw const DuplicateServerException.url('https://bge.example.com'),
      ),
      (
        'offline',
        "You're offline. Connect to a network and try again.",
        () => connectivity.current = ConnectivityState.offline,
      ),
    ]) {
      testWidgets('a failed add hands nothing back: $name', (tester) async {
        final holder = buildHolder();
        final cubit = await pumpApp(
          tester,
          FakeAuthRepository(initialSession: testAuthResponse()),
          holder: holder,
        );
        holder.set(betaLink);
        await tester.pumpAndSettle();
        expect(find.byType(UnknownServerLinkScreen), findsOneWidget);
        await tester.tap(find.byKey(UnknownServerLinkScreen.addButtonKey));
        await tester.pumpAndSettle();
        expect(addressShown(tester), betaAddress);
        fail();

        await submitAsIs(tester);

        expect(find.text(banner), findsOneWidget);
        expect(find.byType(ServerAddScreen), findsOneWidget);
        expect(cubit.state, isA<AppBootstrapReady>());
        expect(scope.active?.displayName, 'My Server');
        expect(holder.peek, isNull);
      });
    }

    testWidgets('first run pre-fills from a held link', (tester) async {
      final holder = buildHolder()..set(betaLink);
      final cubit = await pumpApp(
        tester,
        FakeAuthRepository(),
        firstRun: true,
        holder: holder,
      );
      expect(cubit.state, isA<AppBootstrapNeedsServer>());
      expect(routerOf(tester).state.uri.path, AppRoutes.serverAdd);
      expect(addressShown(tester), betaAddress);

      await submitAsIs(tester);

      // The link never left the slot, and waits for the sign-in.
      expect(orchestrator.calls, ['add $_betaId']);
      expect(cubit.state, isA<AppBootstrapNeedsAuth>());
      expect(routerOf(tester).state.uri.path, AppRoutes.auth);
      expect(holder.peek, betaLink);

      await addedAuth.signIn(email: 'player@example.com', password: 'pw');
      await tester.pumpAndSettle();

      expect(cubit.state, isA<AppBootstrapReady>());
      expect(routerOf(tester).state.uri.path, '/events/ev-1');
      expect(holder.peek, isNull);
    });

    // The person who installs the app because of a link most often opens
    // it again from the first-run screen.
    testWidgets('first run fills in from a link that arrives while it '
        'shows', (tester) async {
      final holder = buildHolder();
      final cubit = await pumpApp(
        tester,
        FakeAuthRepository(),
        firstRun: true,
        holder: holder,
      );
      expect(addressShown(tester), isEmpty);

      holder.set(betaLink);
      await tester.pumpAndSettle();
      expect(addressShown(tester), betaAddress);

      await submitAsIs(tester);

      expect(orchestrator.calls, ['add $_betaId']);
      expect(cubit.state, isA<AppBootstrapNeedsAuth>());
      expect(holder.peek, betaLink);

      await addedAuth.signIn(email: 'player@example.com', password: 'pw');
      await tester.pumpAndSettle();

      expect(routerOf(tester).state.uri.path, '/events/ev-1');
      expect(holder.peek, isNull);
    });

    testWidgets('first run checks the add against a link that arrives while '
        'it shows', (tester) async {
      // Names another server than the one the form finds at its address.
      const otherLink = ServerDeepLink(
        serverId: 'bge-other',
        location:
            '/server/bge-other/event/ev-1'
            '?address=https%3A%2F%2Fbge.example.com',
      );
      final holder = buildHolder()..set(betaLink);
      final cubit = await pumpApp(
        tester,
        FakeAuthRepository(),
        firstRun: true,
        holder: holder,
      );

      holder.set(otherLink);
      await tester.pumpAndSettle();
      await submitAsIs(tester);

      expect(
        find.text(
          "The server at that address isn't the one the link is for, so it "
          "wasn't added.",
        ),
        findsOneWidget,
      );
      expect(orchestrator.calls, isEmpty);
      expect(cubit.state, isA<AppBootstrapNeedsServer>());
    });

    // Replacing the bloc mid-add would drop its success with the server
    // saved, and first run would never move on.
    testWidgets('first run keeps an add under way when a link arrives', (
      tester,
    ) async {
      const laterLink = ServerDeepLink(
        serverId: 'bge-later',
        location:
            '/server/bge-later/event/ev-2'
            '?address=https%3A%2F%2Flater.example.org',
      );
      final holder = buildHolder()..set(betaLink);
      final cubit = await pumpApp(
        tester,
        FakeAuthRepository(),
        firstRun: true,
        holder: holder,
      );
      final add = orchestrator.onAdd!;
      final gate = Completer<void>();
      orchestrator.onAdd = (serverId, displayName) async {
        await gate.future;
        await add(serverId, displayName);
      };

      final button = find.byKey(ServerAddForm.submitButtonKey);
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pump();
      await tester.pump();

      holder.set(laterLink);
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();

      expect(orchestrator.calls, ['add $_betaId']);
      expect(cubit.state, isA<AppBootstrapNeedsAuth>());
      expect(holder.peek, laterLink);
    });

    testWidgets('first run takes up a link that arrived during an add that '
        'failed', (tester) async {
      const laterLink = ServerDeepLink(
        serverId: 'bge-later',
        location:
            '/server/bge-later/event/ev-2'
            '?address=https%3A%2F%2Flater.example.org',
      );
      final holder = buildHolder()..set(betaLink);
      await pumpApp(
        tester,
        FakeAuthRepository(),
        firstRun: true,
        holder: holder,
      );
      final gate = Completer<void>();
      orchestrator.onAdd = (_, _) async {
        await gate.future;
        throw const DuplicateServerException.url('https://bge.example.com');
      };

      final button = find.byKey(ServerAddForm.submitButtonKey);
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pump();
      await tester.pump();

      holder.set(laterLink);
      await tester.pump();
      expect(addressShown(tester), betaAddress);
      gate.complete();
      await tester.pumpAndSettle();

      expect(addressShown(tester), 'https://later.example.org');
    });

    testWidgets('first run keeps what was typed when a link with no address '
        'arrives', (tester) async {
      final holder = buildHolder();
      await pumpApp(
        tester,
        FakeAuthRepository(),
        firstRun: true,
        holder: holder,
      );
      await tester.enterText(
        find.byKey(ServerAddForm.urlFieldKey),
        'mine.example.org',
      );
      // reactive_forms delivers control changes asynchronously.
      await tester.pumpAndSettle();

      holder.set(
        const ServerDeepLink(
          serverId: 'bge-beta',
          location: '/server/bge-beta/event/ev-1',
        ),
      );
      await tester.pumpAndSettle();

      expect(addressShown(tester), 'mine.example.org');
    });

    for (final (name, held) in <(String, NormalizedDeepLink?)>[
      ('no link', null),
      (
        'a link with no address',
        const ServerDeepLink(
          serverId: 'bge-beta',
          location: '/server/bge-beta/event/ev-1',
        ),
      ),
      (
        'an app link',
        (normalizeDeepLink(
          Uri.parse('bge://settings'),
        ) as DeepLinkNormalized).link,
      ),
    ]) {
      testWidgets('first run without a held link starts empty: $name', (
        tester,
      ) async {
        final holder = buildHolder();
        if (held != null) holder.set(held);
        final cubit = await pumpApp(
          tester,
          FakeAuthRepository(),
          firstRun: true,
          holder: holder,
        );

        expect(cubit.state, isA<AppBootstrapNeedsServer>());
        expect(find.byType(ServerAddScreen), findsOneWidget);
        expect(addressShown(tester), isEmpty);
        expect(holder.peek, held);
      });
    }
  });

  group('Manage servers on the sign-in screen', () {
    /// `Gamma`'s row in the open manager.
    final gammaRow = find.byKey(ServersScreen.rowKey(_gammaId));

    testWidgets(
      'on native the sign-in screen offers Manage servers with one server '
      'registered',
      (tester) async {
        final cubit = await pumpApp(tester, FakeAuthRepository());
        expect(cubit.state, isA<AppBootstrapNeedsAuth>());
        expect(find.byType(AuthScreen), findsOneWidget);

        await tapManageServers(tester);
        expect(
          find.byKey(ServersScreen.rowKey('server-uuid-1')),
          findsOneWidget,
        );

        // Back returns to the sign-in screen it was opened from.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(routerOf(tester).state.uri.path, AppRoutes.auth);
        expect(find.byType(ServersScreen), findsNothing);
        expect(find.byType(AuthScreen), findsOneWidget);
        expect(manageServers, findsOneWidget);
      },
    );

    testWidgets('on web it offers nothing', (tester) async {
      final cubit = await pumpApp(tester, FakeAuthRepository(), native: false);
      expect(cubit.state, isA<AppBootstrapNeedsAuth>());
      expect(cubit.orchestrator, isNull);

      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.text('Manage servers'), findsNothing);
    });

    testWidgets('after picking a signed-out server the sign-in screen names '
        'it', (tester) async {
      final cubit = await pumpApp(
        tester,
        FakeAuthRepository(),
        others: [_gamma(FakeAuthRepository())],
      );
      await tapManageServers(tester);

      await tester.tap(gammaRow);
      await tester.pumpAndSettle();

      expect(orchestrator.calls, ['connect $_gammaId']);
      expect(cubit.state, isA<AppBootstrapNeedsAuth>());
      expectSignInFor(tester, name: 'Gamma', serverId: _gammaId);
      expect(find.byType(ServersScreen, skipOffstage: false), findsNothing);
    });

    testWidgets('picking a signed-in server from the manager opened at '
        'sign-in goes home', (tester) async {
      final cubit = await pumpApp(
        tester,
        FakeAuthRepository(),
        others: [
          _gamma(FakeAuthRepository(initialSession: testAuthResponse())),
        ],
      );
      await tapManageServers(tester);

      await tester.tap(gammaRow);
      await tester.pumpAndSettle();

      expect(orchestrator.calls, ['connect $_gammaId']);
      expect(cubit.state, isA<AppBootstrapReady>());
      expect(routerOf(tester).state.uri.path, AppRoutes.home);
      expect(find.byKey(const ValueKey('auth_bloc_$_gammaId')), findsOneWidget);
      expect(find.byType(AuthScreen, skipOffstage: false), findsNothing);
      expect(find.byType(ServersScreen, skipOffstage: false), findsNothing);
    });

    testWidgets('a switch that completes while the sign-in screen shows '
        'renames it', (tester) async {
      final cubit = await pumpApp(
        tester,
        FakeAuthRepository(),
        others: [_gamma(FakeAuthRepository())],
      );
      final switched = Completer<void>();
      orchestrator.onActivate = (_) => switched.future;
      await tapManageServers(tester);
      await tester.tap(gammaRow);
      await tester.pump();

      // Back before the switch finishes: the manager goes, and the switch
      // runs on with nothing left to navigate when it lands.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(routerOf(tester).state.uri.path, AppRoutes.auth);
      expect(find.byType(ServersScreen, skipOffstage: false), findsNothing);
      expect(find.text('My Server'), findsOneWidget);

      switched.complete();
      await tester.pumpAndSettle();

      expect(orchestrator.calls, ['connect $_gammaId']);
      expect(cubit.state, isA<AppBootstrapNeedsAuth>());
      expectSignInFor(tester, name: 'Gamma', serverId: _gammaId);
      // And it offers what Gamma offers, not My Server's sign-in form.
      expect(find.byType(LoginForm), findsNothing);
      expect(
        find.textContaining('no authentication methods configured'),
        findsOneWidget,
      );
    });

    testWidgets("a switch under the sign-in screen drops the old server's "
        'unsent-changes notice', (tester) async {
      await pumpApp(
        tester,
        FakeAuthRepository(),
        others: [_gamma(FakeAuthRepository())],
        unsentChanges: _UnsentChanges(2),
      );
      expect(find.textContaining("2 changes haven't reached"), findsOneWidget);

      orchestrator.activate(_gammaId);
      await tester.pumpAndSettle();

      // Gamma's screen counts Gamma's changes, of which it has none.
      expect(find.textContaining("haven't reached"), findsNothing);
      expectSignInFor(tester, name: 'Gamma', serverId: _gammaId);
    });

    testWidgets('with no server active the sign-in page waits on the '
        'splash', (tester) async {
      await pumpApp(tester, FakeAuthRepository());

      // A server the scope doesn't know: none is active.
      orchestrator.activate('local-gone');
      await tester.pump();
      await tester.pump();

      expect(scope.active, isNull);
      expect(tester.takeException(), isNull);
      expect(routerOf(tester).state.uri.path, AppRoutes.auth);
      expect(find.byType(SplashScreen), findsOneWidget);
      expect(find.byType(AuthScreen), findsNothing);
    });

    testWidgets('a failed session check on native still reaches the manager', (
      tester,
    ) async {
      final cubit = await pumpApp(
        tester,
        FakeAuthRepository(
          sessionCheckError: const AuthNetworkException(message: 'offline'),
        ),
      );
      expect(cubit.state, isA<AppBootstrapNeedsAuth>());
      expect(routerOf(tester).state.uri.path, AppRoutes.auth);
      expect(find.byType(SessionCheckFailedView), findsOneWidget);
      expect(find.byType(AuthScreen), findsNothing);

      await tapManageServers(tester);
      expect(
        find.byKey(ServersScreen.rowKey('server-uuid-1')),
        findsOneWidget,
      );

      // Back returns to the failed check, which is still the answer there.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(routerOf(tester).state.uri.path, AppRoutes.auth);
      expect(find.byType(ServersScreen), findsNothing);
      expect(find.byType(SessionCheckFailedView), findsOneWidget);
      expect(manageServers, findsOneWidget);
    });
  });

  /// A switch ends the user session of the server it leaves, as the real
  /// context's `background()` does.
  void endSessionsOnSwitch(List<_TieredServer> servers) {
    final sessions = {
      for (final server in servers) server.server.serverId: server.session,
    };
    orchestrator.onBackground = (id) => sessions[id]!.deactivate();
  }

  /// Opens the manager from the menu's header.
  Future<void> openManagerFromMenu(WidgetTester tester) async {
    await openMenu(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(MenuDrawer),
        matching: find.byIcon(Icons.unfold_more),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ServersScreen), findsOneWidget);
  }

  /// The app is on [server]'s home, built from its own session, with
  /// nothing built for another server still mounted, offstage included.
  void expectHomeFor(
    WidgetTester tester,
    AppBootstrapCubit cubit,
    _TieredServer server,
  ) {
    expect(cubit.state, isA<AppBootstrapReady>());
    expect(routerOf(tester).state.uri.path, AppRoutes.home);
    expect(find.byType(HomeScreen, skipOffstage: false), findsOneWidget);
    expect(
      tester
          .widget<NavigationShell>(find.byType(NavigationShell))
          .activeServerName,
      server.server.displayName,
    );
    // Home's stats read the session's collection, so the one home shows
    // is the server's own.
    final stats = tester.widgetList<StatsCard>(
      find.byType(StatsCard, skipOffstage: false),
    );
    expect(stats, hasLength(1));
    expect(stats.single.collection, same(server.collection));
    expect(
      find.byType(GameCollectionListScreen, skipOffstage: false),
      findsNothing,
    );
    expect(find.byType(ServersScreen, skipOffstage: false), findsNothing);
  }

  group('a pick made while signed in', () {
    late _TieredServer alpha;
    late _TieredServer beta;

    /// Boots signed in on `Alpha`, with `Beta` registered beside it and
    /// not connected, signed in or not as [betaSignedIn] says, or with
    /// [betaAuth] where a test scripts `Beta`'s session check.
    Future<AppBootstrapCubit> boot(
      WidgetTester tester, {
      bool betaSignedIn = true,
      FakeAuthRepository? betaAuth,
    }) async {
      final alphaAuth = FakeAuthRepository(
        initialSession: _sessionOf('user-alpha'),
      );
      alpha = _tiered(id: 'local-alpha', name: 'Alpha', auth: alphaAuth);
      beta = _tiered(
        id: 'local-beta',
        name: 'Beta',
        auth:
            betaAuth ??
            FakeAuthRepository(
              initialSession: betaSignedIn ? _sessionOf('user-beta') : null,
            ),
      );
      final cubit = await pumpApp(
        tester,
        alphaAuth,
        first: alpha.server,
        others: [beta.server],
      );
      endSessionsOnSwitch([alpha, beta]);
      expect(cubit.state, isA<AppBootstrapReady>());
      expect(alpha.session.activeUserId, 'user-alpha');
      return cubit;
    }

    Finder betaRow() => find.byKey(ServersScreen.rowKey(beta.server.serverId));

    /// Goes to the collection, a page that isn't home, built from
    /// `Alpha`'s session.
    Future<void> openCollection(WidgetTester tester) async {
      await goToDestination(tester, 'collection');
      expect(routerOf(tester).state.uri.path, AppRoutes.collection);
      expect(
        tester
            .widget<GameCollectionListScreen>(
              find.byType(GameCollectionListScreen),
            )
            .repository,
        same(alpha.collection),
      );
    }

    testWidgets('picking a signed-in server from the drawer lands on its '
        'home', (tester) async {
      final cubit = await boot(tester);
      await openCollection(tester);
      await openManagerFromMenu(tester);

      await tester.tap(betaRow());
      await tester.pumpAndSettle();

      expect(orchestrator.calls, ['connect ${beta.server.serverId}']);
      expect(alpha.session.activeUserId, isNull);
      expect(beta.session.activeUserId, 'user-beta');
      expectHomeFor(tester, cubit, beta);
      expect(
        find.byKey(ValueKey('auth_bloc_${alpha.server.serverId}')),
        findsNothing,
      );
    });

    testWidgets('picking a signed-out server from the drawer lands on its '
        'sign-in screen', (tester) async {
      final cubit = await boot(tester, betaSignedIn: false);
      await openCollection(tester);
      await openManagerFromMenu(tester);

      await tester.tap(betaRow());
      await tester.pumpAndSettle();

      expect(orchestrator.calls, ['connect ${beta.server.serverId}']);
      expect(alpha.session.activeUserId, isNull);
      expect(cubit.state, isA<AppBootstrapNeedsAuth>());
      expectSignInFor(tester, name: 'Beta', serverId: beta.server.serverId);
      void expectNoSignedInPages() {
        for (final type in [
          NavigationShell,
          HomeScreen,
          GameCollectionListScreen,
          ServersScreen,
        ]) {
          expect(find.byType(type, skipOffstage: false), findsNothing);
        }
      }

      expectNoSignedInPages();

      // Nothing of Alpha's session is beneath it to go Back to.
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(routerOf(tester).state.uri.path, AppRoutes.auth);
      expectNoSignedInPages();
    });

    testWidgets('picking a server signed in as a user with the same id, '
        'from the manager over home, lands on its home', (tester) async {
      // Two servers can give their users the same id: one restored from
      // the other's backup does.
      final cubit = await boot(
        tester,
        betaAuth: FakeAuthRepository(initialSession: _sessionOf('user-alpha')),
      );
      await openManagerFromMenu(tester);

      await tester.tap(betaRow());
      await tester.pumpAndSettle();

      expect(alpha.session.activeUserId, isNull);
      expect(beta.session.activeUserId, 'user-alpha');
      expectHomeFor(tester, cubit, beta);
    });

    /// Nothing signed in shows but the splash: no home, and no shell around
    /// it to open a screen from.
    void expectSplashAtHome(WidgetTester tester) {
      expect(routerOf(tester).state.uri.path, AppRoutes.home);
      expect(find.byType(SplashScreen), findsOneWidget);
      for (final type in [NavigationShell, HomeScreen, StatsCard]) {
        expect(find.byType(type, skipOffstage: false), findsNothing);
      }
      expect(tester.takeException(), isNull);
    }

    /// Lets a pick or a switch land and the manager finish leaving. Not
    /// `pumpAndSettle`: the splash never settles.
    Future<void> pumpPastSwitch(WidgetTester tester) async {
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    testWidgets("home waits on the splash until the picked server's session "
        'is live', (tester) async {
      final checked = Completer<void>();
      final cubit = await boot(
        tester,
        betaAuth: _HeldAuth(
          checked.future,
          initialSession: _sessionOf('user-beta'),
        ),
      );
      await openManagerFromMenu(tester);

      await tester.tap(betaRow());
      await pumpPastSwitch(tester);

      // Alpha's session ended with the switch, and Beta's isn't known yet.
      expect(alpha.session.activeUserId, isNull);
      expect(beta.session.activeUserId, isNull);
      expect(cubit.state, isA<AppBootstrapReady>());
      expect(find.byType(ServersScreen, skipOffstage: false), findsNothing);
      expectSplashAtHome(tester);

      checked.complete();
      await tester.pumpAndSettle();

      expect(beta.session.activeUserId, 'user-beta');
      expectHomeFor(tester, cubit, beta);
    });

    testWidgets('a switch made elsewhere puts home behind the splash until '
        "the new server's session is live", (tester) async {
      final checked = Completer<void>();
      final cubit = await boot(
        tester,
        betaAuth: _HeldAuth(
          checked.future,
          initialSession: _sessionOf('user-beta'),
        ),
      );

      // As a link for Beta does: no manager, and no navigation after it.
      await orchestrator.connectServer(beta.server.serverId, makeActive: true);
      await pumpPastSwitch(tester);

      expectSplashAtHome(tester);

      checked.complete();
      await tester.pumpAndSettle();

      expectHomeFor(tester, cubit, beta);
    });

    testWidgets('a switch made elsewhere closes a pop-up open over home', (
      tester,
    ) async {
      final cubit = await boot(tester);
      // As a game's quick look does: on the root navigator, over home,
      // reading through the session the switch is about to end.
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(HomeScreen)),
          builder: (_) => const Text('Over home'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Over home'), findsOneWidget);

      // As a link for Beta does: home's page stays, so no guard takes the
      // pop-up down.
      await orchestrator.connectServer(beta.server.serverId, makeActive: true);
      await tester.pumpAndSettle();

      expect(find.text('Over home'), findsNothing);
      expectHomeFor(tester, cubit, beta);
    });

    testWidgets('picking a server whose session check fails lands on its '
        'failed check, which can be tried again', (tester) async {
      final betaAuth = FakeAuthRepository(
        initialSession: _sessionOf('user-beta'),
        sessionCheckError: const AuthNetworkException(message: 'offline'),
      );
      final cubit = await boot(tester, betaAuth: betaAuth);
      await openManagerFromMenu(tester);

      await tester.tap(betaRow());
      await tester.pumpAndSettle();

      expect(cubit.state, isA<AppBootstrapNeedsAuth>());
      expect(routerOf(tester).state.uri.path, AppRoutes.auth);
      expect(find.byType(SessionCheckFailedView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('auth_bloc_local-beta')),
        findsOneWidget,
      );
      for (final type in [NavigationShell, HomeScreen, SplashScreen]) {
        expect(find.byType(type, skipOffstage: false), findsNothing);
      }
      // The way back to the other servers.
      expect(manageServers, findsOneWidget);

      betaAuth.sessionCheckError = null;
      await tester.tap(find.text('Try Again'));
      await tester.pumpAndSettle();

      expectHomeFor(tester, cubit, beta);
    });

    testWidgets('a switch away and straight back, inside one frame, keeps '
        'home', (tester) async {
      final cubit = await boot(tester);

      // Two switches the fake makes without ending a session: what is
      // pinned is that home isn't left behind the splash, with the first
      // server's bloc still mounted and no sign-in outcome to come. The
      // idle delivers the first switch, as the real orchestrator's awaits
      // do, and builds no frame.
      orchestrator.activate(beta.server.serverId);
      await tester.idle();
      orchestrator.activate(alpha.server.serverId);
      await tester.pumpAndSettle();

      expect(
        find.byKey(ValueKey('auth_bloc_${alpha.server.serverId}')),
        findsOneWidget,
      );
      expectHomeFor(tester, cubit, alpha);
    });

    group('a pick that lands after Back from the manager', () {
      /// Picks `Beta` from the manager, held mid-switch until [switched]
      /// completes, then goes Back to the page the manager was opened
      /// over.
      Future<void> pickThenBack(
        WidgetTester tester,
        Completer<void> switched,
      ) async {
        final under = routerOf(tester).state.uri.path;
        await openManagerFromMenu(tester);
        orchestrator.onActivate = (_) => switched.future;
        await tester.tap(betaRow());
        await tester.pump();
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.byType(ServersScreen, skipOffstage: false), findsNothing);
        expect(routerOf(tester).state.uri.path, under);
      }

      testWidgets("still lands on the new server's home", (tester) async {
        final cubit = await boot(tester);
        final switched = Completer<void>();
        await pickThenBack(tester, switched);

        switched.complete();
        await tester.pumpAndSettle();

        expect(orchestrator.calls, ['connect ${beta.server.serverId}']);
        expectHomeFor(tester, cubit, beta);
      });

      testWidgets("from a page that isn't home still lands on the new "
          "server's home", (tester) async {
        final cubit = await boot(tester);
        await openCollection(tester);
        final switched = Completer<void>();
        await pickThenBack(tester, switched);

        switched.complete();
        await tester.pumpAndSettle();

        expect(orchestrator.calls, ['connect ${beta.server.serverId}']);
        expectHomeFor(tester, cubit, beta);
      });
    });
  });

  // #583: a sign-in left running on a server, such as a provider sign-in
  // finishing in the browser, may land after the user has moved to
  // another server. It is kept for that server, and nothing is said.
  testWidgets('a sign-in that finishes on a server while another is active '
      'shows it signed in on return, with no message', (tester) async {
    final alphaAuth = FakeAuthRepository();
    final alpha = _tiered(id: 'local-alpha', name: 'Alpha', auth: alphaAuth);
    final beta = _tiered(
      id: 'local-beta',
      name: 'Beta',
      auth: FakeAuthRepository(initialSession: _sessionOf('user-beta')),
    );
    final cubit = await pumpApp(
      tester,
      alphaAuth,
      first: alpha.server,
      others: [beta.server],
    );
    endSessionsOnSwitch([alpha, beta]);
    expect(cubit.state, isA<AppBootstrapNeedsAuth>());
    expectSignInFor(tester, name: 'Alpha', serverId: alpha.server.serverId);

    // To Beta through Manage servers.
    await tapManageServers(tester);
    await tester.tap(find.byKey(ServersScreen.rowKey(beta.server.serverId)));
    await tester.pumpAndSettle();
    expectHomeFor(tester, cubit, beta);

    // Alpha's sign-in finishes while Beta is active.
    final session = await alphaAuth.signIn(
      email: 'a@example.com',
      password: 'secret',
    );
    await tester.pumpAndSettle();
    expectHomeFor(tester, cubit, beta);
    expect(alpha.session.activeUserId, isNull);

    // Back to Alpha through the menu.
    await openManagerFromMenu(tester);
    await tester.tap(find.byKey(ServersScreen.rowKey(alpha.server.serverId)));
    await tester.pumpAndSettle();

    expect(orchestrator.calls, [
      'connect ${beta.server.serverId}',
      'switch ${alpha.server.serverId}',
    ]);
    expectHomeFor(tester, cubit, alpha);
    expect(alpha.session.activeUserId, session.user.id);
    expect(beta.session.activeUserId, isNull);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.byType(MaterialBanner), findsNothing);
    expect(find.byType(BgeInlineBanner), findsNothing);
  });
}
