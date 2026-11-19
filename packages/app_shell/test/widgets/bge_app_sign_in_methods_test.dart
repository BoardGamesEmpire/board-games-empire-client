import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:auth/auth.dart';
import 'package:bge_test_support/domain.dart';
import 'package:bge_test_support/session.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import '../support/active_server_fakes.dart';
import '../support/no_later_recoveries.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    with NoLaterRecoveries
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

/// Answers with whichever server the test made active last.
class _SwitchableScope implements ActiveServerScope {
  _SwitchableScope(this._read);

  final ActiveServer Function() _read;

  @override
  ActiveServer? get active => _read();

  @override
  Stream<ActiveServer?> watchActive() => Stream.value(_read());
}

const _keycloak = OidcStrategy(
  providerId: 'keycloak',
  displayName: 'Keycloak',
  discoveryUrl:
      'https://sso.example.com/keycloak/.well-known/openid-configuration',
  authorizationEndpoint: '$testAuthBasePath/sign-in/social',
  appSignInEndpoint: '$testAuthBasePath/app-sign-in/start',
  appTokenEndpoint: '$testAuthBasePath/app-sign-in/token',
);

/// The #582 wiring that lives inside [BgeApp]: that it offers the Settings
/// row, hands the route builder to the router, and applies the condition.
/// The router and entry tests use stand-ins and cannot see those lines.
void main() {
  late _MockAppBootstrapCubit cubit;
  late StreamController<AppBootstrapState> states;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    states = StreamController<AppBootstrapState>();
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  tearDown(() => states.close());

  /// The session lease the active server's container answers with, read
  /// whenever the shell asks for it.
  late SessionLease lease;

  /// The active server, read whenever the shell asks for it.
  late ActiveServer active;

  /// A signed-in server that offers a sign-in provider beside the password.
  ActiveServer serverWithLease() {
    final base = buildActiveServer(
      FakeAuthRepository(initialSession: testAuthResponse()),
    );
    base.container.registerFactory<SessionLease>(() => lease);
    return ActiveServer(
      serverId: base.serverId,
      displayName: base.displayName,
      identity: testServerIdentity().copyWith(
        strategies: [testEmailAndPasswordStrategy(), _keycloak],
      ),
      container: base.container,
    );
  }

  Future<GoRouter> pumpSettings(
    WidgetTester tester, {
    bool activeServer = true,
  }) async {
    lease = FakeSessionLease();
    active = serverWithLease();
    when(
      () => cubit.activeServerScope,
    ).thenReturn(activeServer ? _SwitchableScope(() => active) : null);
    whenListen(
      cubit,
      states.stream,
      initialState: const AppBootstrapInitializing(),
    );
    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await tester.pump();
    states.add(const AppBootstrapReady());
    await tester.pumpAndSettle();
    final router =
        tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
              as GoRouter
          ..go(AppRoutes.settings);
    await tester.pumpAndSettle();
    return router;
  }

  SignInMethodsScreen screen(WidgetTester tester) =>
      tester.widget<SignInMethodsScreen>(find.byType(SignInMethodsScreen));

  group('sign-in methods (#582)', () {
    testWidgets('Settings offers "Sign-in methods" for the active server', (
      tester,
    ) async {
      await pumpSettings(tester);

      expect(find.byKey(const Key('settings_sign_in_methods')), findsOneWidget);
      expect(find.text('Sign-in methods'), findsOneWidget);
      // The identity's name, not the display name ("My Server").
      expect(find.text('How you sign in to Test BGE Server'), findsOneWidget);
    });

    testWidgets('activating the row opens the screen over the active '
        "server's auth repository", (tester) async {
      await pumpSettings(tester);

      await tester.tap(find.text('Sign-in methods'));
      await tester.pumpAndSettle();

      expect(find.byType(SignInMethodsScreen), findsOneWidget);
      expect(
        screen(tester).repository,
        same(active.container.get<AuthRepository>()),
      );
      expect(screen(tester).strategies, [_keycloak]);
      // A link comes back to this screen.
      expect(screen(tester).returnPath, AppRoutes.settingsSignInMethods);
      // The repository's rows are what it lists.
      expect(find.text('Password'), findsOneWidget);
    });

    testWidgets('a new session gets a fresh screen', (tester) async {
      final router = await pumpSettings(tester);
      router.go(AppRoutes.settingsSignInMethods);
      await tester.pumpAndSettle();
      State<SignInMethodsScreen> screenState() =>
          tester.state(find.byType(SignInMethodsScreen));
      // go_router builds a page again only when the match list changes, so
      // a page pushed over the screen and popped rebuilds it in place.
      Future<void> rebuildThePage() async {
        unawaited(router.push(AppRoutes.settings));
        await tester.pumpAndSettle();
        router.pop();
        await tester.pumpAndSettle();
      }

      final first = screenState();
      expect(screen(tester).key, ValueKey((active, lease)));

      // The same session: the page is built again, the screen stays.
      await rebuildThePage();
      expect(screenState(), same(first));

      // Another session on the same server container: a fresh screen, and
      // nothing the last one held.
      lease = FakeSessionLease();
      await rebuildThePage();
      expect(screen(tester).key, ValueKey((active, lease)));
      expect(screenState(), isNot(same(first)));
      expect(first.mounted, isFalse);
    });

    testWidgets('another server under the same lease gets a fresh screen', (
      tester,
    ) async {
      final router = await pumpSettings(tester);
      router.go(AppRoutes.settingsSignInMethods);
      await tester.pumpAndSettle();
      final first = tester.state(find.byType(SignInMethodsScreen));
      final firstRepository = screen(tester).repository;

      // Two signed-out servers share the one `const` lease, so the server
      // is what tells their screens apart.
      active = serverWithLease();
      unawaited(router.push(AppRoutes.settings));
      await tester.pumpAndSettle();
      router.pop();
      await tester.pumpAndSettle();

      expect(
        screen(tester).repository,
        same(active.container.get<AuthRepository>()),
      );
      expect(screen(tester).repository, isNot(same(firstRepository)));
      expect(
        tester.state(find.byType(SignInMethodsScreen)),
        isNot(same(first)),
      );
      expect(first.mounted, isFalse);
    });

    testWidgets('Back from the screen returns to Settings', (tester) async {
      final router = await pumpSettings(tester);
      await tester.tap(find.text('Sign-in methods'));
      await tester.pumpAndSettle();
      expect(find.byType(SignInMethodsScreen), findsOneWidget);

      router.pop();
      await tester.pumpAndSettle();

      expect(find.byType(SignInMethodsScreen), findsNothing);
      expect(find.byType(SettingsScreen), findsOneWidget);
    });

    testWidgets('no row, and /settings/sign-in-methods falls back, when no '
        'server is active', (tester) async {
      final router = await pumpSettings(tester, activeServer: false);

      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(find.text('Sign-in methods'), findsNothing);

      router.go(AppRoutes.settingsSignInMethods);
      await tester.pumpAndSettle();

      expect(find.byType(NotYetAvailableScreen), findsOneWidget);
      expect(find.byType(SignInMethodsScreen), findsNothing);
    });
  });
}
