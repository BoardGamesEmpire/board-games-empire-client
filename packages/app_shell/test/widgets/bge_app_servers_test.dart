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
/// refused where it was typed.
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
  Future<AppBootstrapCubit> pumpApp(
    WidgetTester tester,
    FakeAuthRepository repo,
  ) async {
    orchestrator = FakeServerOrchestrator();
    addTearDown(orchestrator.close);
    final alpha = buildActiveServer(repo);
    orchestrator.activate(alpha.serverId);
    scope = _OrchestratorScope(orchestrator, alpha);
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
      testRegisteredServer(alpha.serverId, alpha.displayName),
    ]);
    addTearDown(registered.close);

    final cubit = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(
        outcomes: [
          BootstrapResult(
            hasServer: true,
            activeServerScope: scope,
            orchestrator: orchestrator,
            registeredServers: registered,
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

  /// Opens the manager, then its add page.
  Future<void> openAdd(WidgetTester tester) async {
    unawaited(routerOf(tester).push<void>(AppRoutes.servers));
    await tester.pumpAndSettle();
    expect(find.byType(ServersScreen), findsOneWidget);

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

  /// The app is on the sign-in screen for `Beta`, the server just added,
  /// with nothing of the manager left to go Back to.
  Future<void> expectBetaSignIn(
    WidgetTester tester,
    AppBootstrapCubit cubit,
  ) async {
    expect(orchestrator.calls, ['add $_betaId']);
    expect(cubit.state, isA<AppBootstrapNeedsAuth>());
    expect(routerOf(tester).state.uri.path, AppRoutes.auth);
    expect(find.byType(AuthScreen), findsOneWidget);
    expect(scope.active?.displayName, 'Beta');
    // The sign-in screen names the new server, drawn and announced, and
    // nothing anywhere still names the old one. The signed-out flow's
    // sign-in page was built before the add, for the old server.
    final handle = tester.ensureSemantics();
    expect(
      find.descendant(
        of: find.byType(AuthScreen),
        matching: find.text('Beta'),
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Server: Beta'), findsOneWidget);
    expect(find.text('My Server', skipOffstage: false), findsNothing);
    handle.dispose();
    // The sign-in screen's session is the new server's.
    expect(find.byKey(const ValueKey('auth_bloc_$_betaId')), findsOneWidget);
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
    await openAdd(tester);

    await submit(tester);

    await expectBetaSignIn(tester, cubit);
  });

  testWidgets('a server already added is refused inline', (tester) async {
    final cubit = await pumpApp(
      tester,
      FakeAuthRepository(initialSession: testAuthResponse()),
    );
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
}
