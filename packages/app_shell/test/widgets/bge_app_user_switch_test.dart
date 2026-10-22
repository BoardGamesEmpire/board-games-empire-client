import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:auth/auth.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:di/di.dart' show DependencyContainerImpl;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/dto.dart';
import 'package:network_interface/network_interface.dart'
    show DataGatewayRemoteDataSource;

import '../support/active_server_fakes.dart';
import '../support/fake_platform_bootstrap.dart';

/// Records the shell's calls in order, serialized like every real
/// [UserSessionScope].
class _RecordingUserSessionScope implements UserSessionScope {
  _RecordingUserSessionScope({this.onActivate, this.holdActivation});

  /// Runs inside [activate], where a real scope's installers would register
  /// the user's services.
  final void Function(String userId)? onActivate;

  /// What [activate] waits on for a user, as a real scope waits on its
  /// installers. Null for no wait.
  final Future<void>? Function(String userId)? holdActivation;

  final calls = <String>[];
  String? _activeUserId;
  Future<void> _ops = Future<void>.value();

  @override
  String? get activeUserId => _activeUserId;

  @override
  Future<void> activate(String userId) => _enqueue(() async {
    calls.add('activate:$userId');
    await holdActivation?.call(userId);
    onActivate?.call(userId);
    _activeUserId = userId;
  });

  @override
  Future<void> deactivate() => _enqueue(() async {
    calls.add('deactivate');
    _activeUserId = null;
  });

  Future<void> _enqueue(Future<void> Function() op) {
    final result = _ops.then((_) => op());
    _ops = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }
}

AuthResponse _sessionOf(String id, String username) => AuthResponse(
  token: null,
  user: AuthUser(
    id: id,
    username: username,
    email: '$id@example.com',
    emailVerified: true,
    createdAt: DateTime(2099),
    updatedAt: DateTime(2099),
  ),
  expiresAt: DateTime(2099).toUtc(),
);

/// A different user arriving over a live session (#432).
///
/// On web every tab shares one session cookie, so a sign-in in another tab
/// moves this tab's session to another user without it ever being signed
/// out. The repository reports the new user; the shell ends the first
/// user's session and starts the second's, in place.
void main() {
  Future<void> noopHydrated(PlatformBootstrap _) async {}

  late FakeAuthRepository repo;
  late _RecordingUserSessionScope sessionScope;
  late AppBootstrapCubit cubit;

  final noticeText = find.text(
    'other signed in from another tab, so this tab switched to their account.',
  );

  void switchToSecondUser() => repo.emitAuthState(
    AuthStateAuthenticated(session: _sessionOf('u2', 'other')),
  );

  // Any user's notice, not only the second user's.
  final anyNotice = find.textContaining('signed in from another tab');

  Future<void> signedInAsFirstUser(
    WidgetTester tester, {
    void Function(DependencyContainerImpl container, String userId)? onActivate,
    Future<void>? Function(String userId)? holdActivation,
    FakeAuthRepository Function()? repository,
  }) async {
    repo =
        repository?.call() ??
        FakeAuthRepository(initialSession: sampleSession());
    late final ActiveServer active;
    sessionScope = _RecordingUserSessionScope(
      holdActivation: holdActivation,
      onActivate: onActivate == null
          ? null
          : (userId) =>
                onActivate(active.container as DependencyContainerImpl, userId),
    );
    active = buildActiveServer(repo, userSessionScope: sessionScope);
    cubit = AppBootstrapCubit(
      platformBootstrap: FakePlatformBootstrap(
        activeServerScope: FakeActiveServerScope(active),
      ),
      hydratedStorageInitializer: noopHydrated,
    );
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
  }

  testWidgets('ends the first user\'s session and starts the second\'s, '
      'without ever showing the sign-in screen', (tester) async {
    await signedInAsFirstUser(tester);

    switchToSecondUser();
    for (var frame = 0; frame < 10; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.byType(AuthScreen), findsNothing);
    }
    await tester.pumpAndSettle();

    expect(sessionScope.calls, ['activate:u1', 'deactivate', 'activate:u2']);
    expect(sessionScope.activeUserId, 'u2');
    expect(cubit.state, const AppBootstrapReady());
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  // The first user's scope is torn down as the switch begins, and home's
  // entries open screens over its services.
  testWidgets('shows no home while the second user\'s session is starting', (
    tester,
  ) async {
    final starting = Completer<void>();
    await signedInAsFirstUser(
      tester,
      holdActivation: (userId) => userId == 'u2' ? starting.future : null,
    );

    switchToSecondUser();
    await tester.pump();
    await tester.pump();

    expect(find.byType(HomeScreen), findsNothing);
    expect(find.byType(SplashScreen), findsOneWidget);

    starting.complete();
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('tells the user once which account the tab now shows', (
    tester,
  ) async {
    await signedInAsFirstUser(tester);
    expect(noticeText, findsNothing);

    switchToSecondUser();
    await tester.pumpAndSettle();

    expect(noticeText, findsOneWidget);
  });

  testWidgets('closes a screen the first user opened', (tester) async {
    await signedInAsFirstUser(tester);
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    // Any screen pushed above home will do. Settings renders its placeholder
    // here, since this app was built without the settings cubits.
    await tester.tap(find.byKey(HomeScreen.entryKey('settings')));
    await tester.pumpAndSettle();
    expect(find.byType(NotYetAvailableScreen), findsOneWidget);

    switchToSecondUser();
    await tester.pumpAndSettle();

    expect(find.byType(NotYetAvailableScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('builds home from the second user\'s services', (tester) async {
    // The second user may read DataGateways and the first may not, so the
    // Admin entry is what tells the two homes apart.
    final access = DataGatewayAccess(remote: _UnusedDataGatewayRemote())
      ..readGranted();
    addTearDown(access.dispose);
    await signedInAsFirstUser(
      tester,
      onActivate: (container, userId) {
        if (userId == 'u2') {
          container.registerSingleton<DataGatewayAccess>(access);
        }
      },
    );
    final adminEntry = find.byKey(HomeScreen.entryKey('admin'));
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    expect(adminEntry, findsNothing);
    tester.firstState<ScaffoldState>(find.byType(Scaffold)).closeDrawer();
    await tester.pumpAndSettle();

    switchToSecondUser();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(adminEntry, findsOneWidget);
  });

  testWidgets('a new session for the same user is not a switch', (
    tester,
  ) async {
    await signedInAsFirstUser(tester);

    final renewed = sampleSession();
    repo.emitAuthState(
      AuthStateAuthenticated(
        session: AuthResponse(
          token: renewed.token,
          user: renewed.user,
          expiresAt: DateTime(2100).toUtc(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(sessionScope.calls, ['activate:u1']);
    expect(noticeText, findsNothing);
  });

  // #432's own scenario: another tab signs out, and later signs in as
  // someone else. This tab hears the sign-out first and shows the sign-in
  // form, so the second user arrives over no session at all.
  group('another user signing in after this tab was signed out', () {
    Future<void> signedOutElsewhere(WidgetTester tester) async {
      await signedInAsFirstUser(
        tester,
        repository: () => _SignsInAsSecondUser(initialSession: sampleSession()),
      );
      repo.emitAuthState(const AuthStateUnauthenticated());
      await tester.pumpAndSettle();
      expect(find.byType(AuthScreen), findsOneWidget);
    }

    testWidgets('tells the user which account the tab now shows', (
      tester,
    ) async {
      await signedOutElsewhere(tester);

      switchToSecondUser();
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(noticeText, findsOneWidget);
    });

    testWidgets('says nothing when the same user signs back in', (
      tester,
    ) async {
      await signedOutElsewhere(tester);

      repo.emitAuthState(AuthStateAuthenticated(session: sampleSession()));
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(anyNotice, findsNothing);
    });

    testWidgets('says nothing about a sign-in made in this tab', (
      tester,
    ) async {
      await signedOutElsewhere(tester);

      tester
          .element(find.byType(AuthScreen))
          .read<AuthBloc>()
          .add(const AuthSignInRequested(email: 'u2@x.io', password: 'pw'));
      await tester.pumpAndSettle();

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(sessionScope.activeUserId, 'u2');
      expect(anyNotice, findsNothing);
    });
  });

  // The switch shows the splash until the second user's scope is live. A
  // failed activation never gets there, so the recovery sign-out must not
  // leave that splash behind for the next sign-in.
  testWidgets('a second user whose session fails to start is signed out, and '
      'a later sign-in reaches home', (tester) async {
    await signedInAsFirstUser(
      tester,
      holdActivation: (userId) =>
          userId == 'u2' ? Future.error(StateError('activation')) : null,
    );

    switchToSecondUser();
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(cubit.state, isA<AppBootstrapNeedsAuth>());
    expect(noticeText, findsNothing);

    repo.emitAuthState(AuthStateAuthenticated(session: sampleSession()));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(SplashScreen), findsNothing);
  });
}

/// Signs in as the second user, so a sign-in made in this tab changes the
/// user just as one heard from another tab does.
class _SignsInAsSecondUser extends FakeAuthRepository {
  _SignsInAsSecondUser({super.initialSession});

  @override
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    final session = _sessionOf('u2', 'other');
    emitAuthState(AuthStateAuthenticated(session: session));
    return session;
  }
}

/// A remote the Admin test never reaches: its access is settled by hand.
class _UnusedDataGatewayRemote implements DataGatewayRemoteDataSource {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
