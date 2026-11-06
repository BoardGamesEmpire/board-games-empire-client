import 'package:app_shell/app_shell.dart';
import 'package:auth/auth.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:di/di.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:server_onboarding/server_onboarding.dart';

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockServerOrchestrator extends Mock implements ServerOrchestrator {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockSyncOperationSender extends Mock implements SyncOperationSender {}

/// Never reached: nothing here submits the server-add form.
class _UnusedWellKnownClient implements WellKnownClient {
  @override
  Future<ServerIdentity> fetchIdentity(String serverUrl) =>
      throw UnimplementedError('the form is never submitted');
}

class _OnlineConnectivity implements ConnectivityService {
  @override
  ConnectivityState get current => ConnectivityState.online;

  @override
  Stream<ConnectivityState> watch() =>
      Stream<ConnectivityState>.value(ConnectivityState.online);
}

/// A device that can sign in through a provider, so the provider buttons are
/// enabled and Tab reaches them.
class _ProviderReadyAuthRepository extends FakeAuthRepository {
  @override
  ProviderSignInAvailability get providerSignInAvailability =>
      const ProviderSignInAvailable();
}

OidcStrategy _provider(String id, String name) => OidcStrategy(
  providerId: id,
  displayName: name,
  discoveryUrl: 'https://sso.example.com/$id/.well-known/openid-configuration',
  authorizationEndpoint: '/api/auth/sign-in/social',
  appSignInEndpoint: '/api/auth/app-sign-in/start',
  appTokenEndpoint: '/api/auth/app-sign-in/token',
);

/// [serverIdentity] with two sign-in providers after its email strategy.
ServerIdentity _identityWithProviders() {
  final base = serverIdentity();
  return base.copyWith(
    strategies: [
      ...base.strategies,
      _provider('keycloak', 'Keycloak'),
      _provider('github', 'GitHub'),
    ],
  );
}

/// Keyboard flows through the real app root (#50): Tab follows the order a
/// screen reads in, Shift+Tab walks it back, nothing traps focus, and focus
/// goes back to the control that opened a route once the route closes.
///
/// The harnesses are the ones `server_add_route_test.dart` (server-add),
/// `bge_app_auth_wiring_test.dart` (sign-in) and
/// `bge_app_household_menu_test.dart` (the signed-in home) build.
void main() {
  late SemanticsHandle semantics;

  setUp(() {
    // `tabOrder` names each stop from the semantics tree.
    semantics = SemanticsBinding.instance.ensureSemantics();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  tearDown(() => semantics.dispose());

  testWidgets('server add: Tab follows reading order with no trap', (
    tester,
  ) async {
    // The composition native's root module registers for /server-add.
    final container = DependencyContainerImpl()
      ..registerLazySingleton<WellKnownClient>(_UnusedWellKnownClient.new)
      ..registerLazySingleton<VersionNegotiator>(VersionNegotiatorImpl.new)
      ..registerLazySingleton<ConnectivityService>(_OnlineConnectivity.new)
      ..registerSingleton<BuildInfo>(BuildInfo.unknown);
    container.registerLazySingleton<ServerOnboardingDeps>(
      () => ServerOnboardingDeps.from(container),
    );
    addTearDown(container.dispose);
    final cubit = _MockAppBootstrapCubit();
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapNeedsServer(),
    );
    when(() => cubit.orchestrator).thenReturn(_MockServerOrchestrator());
    when(() => cubit.activeServerScope).thenReturn(null);

    await tester.pumpWidget(
      BgeApp(bootstrapCubit: cubit, rootContainer: container),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ServerAddScreen), findsOneWidget);

    // Title and intro are text, then the address, the nickname and the
    // submit, top to bottom.
    await expectTraversable(
      tester,
      expectedOrder: ['Server address', 'Nickname (optional)', 'Connect'],
    );
  });

  testWidgets('sign in: Tab follows reading order with no trap', (
    tester,
  ) async {
    final repo = _ProviderReadyAuthRepository(); // no session
    final server = buildActiveServer(repo);
    final cubit = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(
        activeServerScope: FakeActiveServerScope(
          ActiveServer(
            serverId: server.serverId,
            displayName: server.displayName,
            identity: _identityWithProviders(),
            container: server.container,
          ),
        ),
      ),
      hydratedStorageInitializer: (_) async {},
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();
    expect(find.byType(AuthScreen), findsOneWidget);

    // The email form top to bottom, the password's show toggle at the end of
    // its field, the switch to register under the submit, then the provider
    // buttons below the "or" divider. The email field reads its hint with
    // its label.
    await expectTraversable(
      tester,
      expectedOrder: [
        'Email\nEnter your email address',
        'Password',
        'Show password',
        'Sign In',
        "Don't have an account? Register",
        'Continue with Keycloak',
        'Continue with GitHub',
      ],
    );
  });

  testWidgets('home → create household: Tab follows reading order with no '
      'trap on each, Escape closes the drawer back to its opener, and back '
      'returns focus to the opener', (tester) async {
    final repository = _MockHouseholdRepository();
    // A household in the cache, so the list shows rows and the floating
    // Create is the only create control.
    when(repository.watchHouseholds).thenAnswer(
      (_) => Stream<List<Household>>.value([
        Household(
          id: 'hh_1',
          name: 'Sunday Crew',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ]),
    );
    final cubit = _MockAppBootstrapCubit();
    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: sampleSession()),
          householdRepository: repository,
          // The create route's guard: without a sender, the list offers no
          // create (#121).
          syncOperationSender: _MockSyncOperationSender(),
        ),
      ),
    );
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapReady(),
    );

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);

    // This container registers none of the sections' sources, so home shows
    // its welcome line, and the app bar's menu button is its one stop.
    await expectTraversable(tester, expectedOrder: ['Open navigation menu']);

    // The drawer, from the menu button. Its destinations, then its action
    // under the divider. Material reads each destination with "Tab n of m"
    // (<A11Y-13>).
    final menu = find.byIcon(Icons.menu);
    final menuNode = Focus.of(tester.element(menu));
    await activateByKeyboard(tester, menu);
    expect(find.byKey(HomeScreen.drawerKey), findsOneWidget);
    await expectTraversable(
      tester,
      expectedOrder: [
        'Households\nTab 1 of 3',
        'Send feedback\nTab 2 of 3',
        'Settings\nTab 3 of 3',
        'Sign Out',
      ],
    );

    // Escape closes it, and focus goes back to the menu button.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(HomeScreen.drawerKey), findsNothing);
    expect(FocusManager.instance.primaryFocus, same(menuNode));

    // Open again, then the households entry.
    await activateByKeyboard(tester, menu);
    expect(find.byKey(HomeScreen.drawerKey), findsOneWidget);
    await activateByKeyboard(
      tester,
      find.descendant(
        of: find.byKey(HomeScreen.entryKey('households')),
        matching: find.text('Households'),
      ),
    );
    expect(find.byType(HouseholdListScreen), findsOneWidget);

    // A page route takes no Escape: only a route the barrier dismisses does.
    // Its back button is how a keyboard leaves it.
    await expectFocusReturnsAfterDialog(
      tester,
      opener: find.descendant(
        of: find.byKey(HouseholdListScreen.createFabKey),
        matching: find.text('Create household'),
      ),
      dismiss: () async {
        expect(find.byType(CreateHouseholdScreen), findsOneWidget);
        // The back button, then the form top to bottom.
        await expectTraversable(
          tester,
          expectedOrder: [
            'Back',
            'Household name',
            'Description (optional)',
            'Create household',
          ],
        );
        await activateByKeyboard(
          tester,
          find.descendant(
            of: find.byType(BackButton),
            matching: find.byType(Icon),
          ),
        );
      },
    );
    expect(find.byType(CreateHouseholdScreen), findsNothing);
    expect(find.byType(HouseholdListScreen), findsOneWidget);
  });
}
