import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:auth/auth.dart';
import 'package:di/di.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

import '../support/fake_platform_bootstrap.dart';

/// #135 shell wiring: the auth gate listener drives the [UserSessionScope]
/// resolved from the active server's container — activate on any transition
/// into authenticated, deactivate on any transition out — and tolerates a
/// container without the seam (web until #137).

/// A fake per-server [AuthRepository] with scriptable session state,
/// mirroring the fake in `bge_app_auth_wiring_test.dart`.
class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository({AuthResponse? initialSession})
    : _session = initialSession;

  AuthResponse? _session;
  AuthState _currentState = const AuthStateUnknown();
  final _controller = StreamController<AuthState>.broadcast();

  @override
  AuthState get currentAuthState => _currentState;

  @override
  Future<AuthResponse?> getSession() async => _session;

  @override
  Future<void> signOut() async {
    _session = null;
    _setState(const AuthStateUnauthenticated());
  }

  @override
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    _session = _sampleSession();
    _setState(AuthStateAuthenticated(session: _session!));
    return _session!;
  }

  @override
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String username,
    String? firstName,
    String? lastName,
  }) async {
    _session = _sampleSession();
    _setState(AuthStateAuthenticated(session: _session!));
    return _session!;
  }

  @override
  Future<AuthResponse?> getCachedSession() async => _session;

  @override
  Stream<AuthState> watchAuthState() {
    return Stream.multi((controller) {
      controller.add(_currentState);
      final sub = _controller.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = sub.cancel;
    });
  }

  void _setState(AuthState next) {
    _currentState = next;
    if (!_controller.isClosed) _controller.add(next);
  }
}

/// Records every [UserSessionScope] call in order so the tests can assert
/// the shell drives the seam symmetrically with the auth transitions.
class _RecordingUserSessionScope implements UserSessionScope {
  final calls = <String>[];
  String? _activeUserId;

  @override
  String? get activeUserId => _activeUserId;

  @override
  Future<void> activate(String userId) async {
    calls.add('activate:$userId');
    _activeUserId = userId;
  }

  @override
  Future<void> deactivate() async {
    calls.add('deactivate');
    _activeUserId = null;
  }
}

/// A seam that always fails: activation failure must sign the user out
/// (never strand an authenticated session without services), and
/// deactivation failure must be logged without breaking the sign-out
/// flow (#135 review).
class _ThrowingUserSessionScope implements UserSessionScope {
  @override
  String? get activeUserId => null;

  @override
  Future<void> activate(String userId) async =>
      throw StateError('activation boom');

  @override
  Future<void> deactivate() async => throw StateError('deactivation boom');
}

/// A seam whose [deactivate] completes only when the test releases it,
/// proving the gate routes away *before* the scope pop finishes — no live
/// home widget over disposed repositories (#135 review).
class _GatedUserSessionScope implements UserSessionScope {
  final deactivateGate = Completer<void>();
  var deactivateStarted = false;

  @override
  String? get activeUserId => null;

  @override
  Future<void> activate(String userId) async {}

  @override
  Future<void> deactivate() {
    deactivateStarted = true;
    return deactivateGate.future;
  }
}

/// Minimal [ActiveServerScope] emitting one fixed active server.
class _FakeActiveServerScope implements ActiveServerScope {
  _FakeActiveServerScope(this._active);
  final ActiveServer _active;

  @override
  ActiveServer? get active => _active;

  @override
  Stream<ActiveServer?> watchActive() => Stream.value(_active);
}

const _kAuthBase = '/api/auth';

ServerIdentity _identity() => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: 'https://api.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: '$_kAuthBase/get-session',
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
  strategies: [
    const EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '$_kAuthBase/sign-in/email',
      signUpEndpoint: '$_kAuthBase/sign-up/email',
    ),
  ],
);

AuthResponse _sampleSession() => AuthResponse(
  token: 'tok-abc',
  user: AuthUser(
    id: 'u1',
    username: 'tester',
    email: 'u1@example.com',
    emailVerified: true,
    createdAt: DateTime(2099),
    updatedAt: DateTime(2099),
  ),
  expiresAt: DateTime(2099).toUtc(),
);

ActiveServer _activeServer(
  AuthRepository repo, {
  UserSessionScope? sessionScope,
}) {
  final container = DependencyContainerImpl()
    ..registerSingleton<AuthRepository>(repo);
  if (sessionScope != null) {
    container.registerSingleton<UserSessionScope>(sessionScope);
  }
  return ActiveServer(
    serverId: 'server-uuid-1',
    displayName: 'My Server',
    identity: _identity(),
    container: container,
  );
}

void main() {
  Future<void> noopHydrated(PlatformBootstrap _) async {}

  AppBootstrapCubit buildCubit(
    _FakeAuthRepository repo, {
    UserSessionScope? sessionScope,
  }) => AppBootstrapCubit(
    platformBootstrap: FakePlatformBootstrap(
      activeServerScope: _FakeActiveServerScope(
        _activeServer(repo, sessionScope: sessionScope),
      ),
    ),
    hydratedStorageInitializer: noopHydrated,
  );

  testWidgets('a restored session activates the user-session scope for the '
      'session user before home renders', (tester) async {
    final repo = _FakeAuthRepository(initialSession: _sampleSession());
    final sessionScope = _RecordingUserSessionScope();
    final cubit = buildCubit(repo, sessionScope: sessionScope);
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();

    expect(find.byType(HomePlaceholderScreen), findsOneWidget);
    expect(sessionScope.calls, ['activate:u1']);
    expect(sessionScope.activeUserId, 'u1');
  });

  testWidgets('sign-out deactivates the user-session scope', (tester) async {
    final repo = _FakeAuthRepository(initialSession: _sampleSession());
    final sessionScope = _RecordingUserSessionScope();
    final cubit = buildCubit(repo, sessionScope: sessionScope);
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();
    expect(sessionScope.calls, ['activate:u1']);

    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(sessionScope.calls, ['activate:u1', 'deactivate']);
    expect(sessionScope.activeUserId, isNull);
  });

  testWidgets('the no-session startup path only issues an idempotent '
      'deactivate', (tester) async {
    final repo = _FakeAuthRepository(); // no session
    final sessionScope = _RecordingUserSessionScope();
    final cubit = buildCubit(repo, sessionScope: sessionScope);
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    // The unauthenticated startup transition drives a deactivate; the seam
    // contract makes it a harmless no-op. No activation may occur.
    expect(sessionScope.calls, isNot(contains(startsWith('activate:'))));
  });

  testWidgets('a container without a UserSessionScope keeps the auth flow '
      'working (web until #137)', (tester) async {
    final repo = _FakeAuthRepository(initialSession: _sampleSession());
    final cubit = buildCubit(repo); // seam not registered
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();
    expect(find.byType(HomePlaceholderScreen), findsOneWidget);

    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
  });

  testWidgets('a failed activation signs the user out instead of stranding '
      'an authenticated session without services', (tester) async {
    final repo = _FakeAuthRepository(initialSession: _sampleSession());
    final cubit = buildCubit(repo, sessionScope: _ThrowingUserSessionScope());
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();

    // Activation threw → the gate never advanced; the dispatched sign-out
    // converged the session to unauthenticated. The deactivation on that
    // sign-out transition also threw and was logged — the flow survives
    // both.
    expect(find.byType(HomePlaceholderScreen), findsNothing);
    expect(find.byType(AuthScreen), findsOneWidget);
  });

  testWidgets('sign-out routes away before the scope pop completes — no '
      'live home widget over disposed repositories', (tester) async {
    final repo = _FakeAuthRepository(initialSession: _sampleSession());
    final sessionScope = _GatedUserSessionScope();
    final cubit = buildCubit(repo, sessionScope: sessionScope);
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();
    expect(find.byType(HomePlaceholderScreen), findsOneWidget);

    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();

    // The pop is still held open by the gate, yet home is already gone.
    expect(sessionScope.deactivateStarted, isTrue);
    expect(find.byType(HomePlaceholderScreen), findsNothing);
    expect(find.byType(AuthScreen), findsOneWidget);

    sessionScope.deactivateGate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(AuthScreen), findsOneWidget);
  });
}
