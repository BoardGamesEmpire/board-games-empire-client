import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:app_shell/src/servers/servers_screen.dart';
import 'package:auth/auth.dart';
import 'package:bge_test_support/domain.dart';
import 'package:di/di.dart'
    show DependencyContainerImpl, VersionNegotiatorImpl, replayThenForward;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:server_onboarding/server_onboarding.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';
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

class _WellKnownClient implements WellKnownClient {
  @override
  Future<ServerIdentity> fetchIdentity(String serverUrl) async => _betaIdentity;
}

class _OnlineConnectivity implements ConnectivityService {
  @override
  ConnectivityState get current => ConnectivityState.online;

  @override
  Stream<ConnectivityState> watch() => Stream.value(ConnectivityState.online);
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

  /// The root container the add flow resolves its collaborators from.
  DependencyContainerImpl rootContainer() {
    final container = DependencyContainerImpl()
      ..registerLazySingleton<WellKnownClient>(_WellKnownClient.new)
      ..registerLazySingleton<VersionNegotiator>(VersionNegotiatorImpl.new)
      ..registerLazySingleton<ConnectivityService>(_OnlineConnectivity.new)
      ..registerSingleton<BuildInfo>(BuildInfo.unknown);
    container.registerLazySingleton<ServerOnboardingDeps>(
      () => ServerOnboardingDeps.from(container),
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Boots the app on one server, `My Server`, signed in or not as [repo]
  /// says. An added server is active and signed out, as a new one is.
  ///
  /// [others] are registered too, and not connected. [native] false boots
  /// as web does: no orchestrator and no registry. [unsentChanges] counts
  /// `My Server`'s changes that haven't reached it.
  Future<AppBootstrapCubit> pumpApp(
    WidgetTester tester,
    FakeAuthRepository repo, {
    List<ActiveServer> others = const [],
    bool native = true,
    UnsentChangesNoticeRepository? unsentChanges,
  }) async {
    orchestrator = FakeServerOrchestrator();
    addTearDown(orchestrator.close);
    final alpha = buildActiveServer(repo, unsentChangesNotice: unsentChanges);
    orchestrator.activate(alpha.serverId);
    scope = _OrchestratorScope(orchestrator, alpha);
    for (final other in others) {
      scope.servers[other.serverId] = other;
    }
    orchestrator.onAdd = (serverId, displayName) {
      final added = buildActiveServer(FakeAuthRepository(), serverId: serverId);
      scope.servers[serverId] = ActiveServer(
        serverId: serverId,
        displayName: displayName,
        identity: _betaIdentity,
        container: added.container,
      );
    };
    final registered = FakeRegisteredServers([
      for (final server in [alpha, ...others])
        testRegisteredServer(server.serverId, server.displayName),
    ]);
    addTearDown(registered.close);

    final cubit = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(
        outcomes: [
          if (native)
            BootstrapResult(
              hasServer: true,
              activeServerScope: scope,
              orchestrator: orchestrator,
              registeredServers: registered,
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
      BgeApp(bootstrapCubit: cubit, rootContainer: rootContainer()),
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
}
