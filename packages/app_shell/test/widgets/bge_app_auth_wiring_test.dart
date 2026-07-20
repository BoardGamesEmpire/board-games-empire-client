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

/// A fake per-server [AuthRepository] with scriptable session state,
/// backing the auth bloc the shell provisions from the scope.
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

  // Mirrors the production repositories: seed the current state, then pipe
  // subsequent transitions from [_controller]. Previously this returned a
  // detached `Stream.value(...)`, so the transitions emitted by
  // signOut()/signIn() were never observable and the fake could mask
  // bloc↔repository mirroring regressions (PR #103 review).
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

ActiveServer _activeServer(AuthRepository repo) {
  final container = DependencyContainerImpl()
    ..registerSingleton<AuthRepository>(repo);
  return ActiveServer(
    serverId: 'server-uuid-1',
    displayName: 'My Server',
    identity: _identity(),
    container: container,
  );
}

BgeApp _app(AppBootstrapCubit cubit) => BgeApp(bootstrapCubit: cubit);

void main() {
  Future<void> noopHydrated(PlatformBootstrap _) async {}

  AppBootstrapCubit buildCubit(_FakeAuthRepository repo) => AppBootstrapCubit(
    platformBootstrap: FakePlatformBootstrap(
      activeServerScope: _FakeActiveServerScope(_activeServer(repo)),
    ),
    hydratedStorageInitializer: noopHydrated,
  );

  testWidgets('a restored session advances the gate to the home '
      'placeholder (splash → home, no form flash)', (tester) async {
    final repo = _FakeAuthRepository(initialSession: _sampleSession());
    final cubit = buildCubit(repo);
    addTearDown(cubit.close);

    await tester.pumpWidget(_app(cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();

    expect(find.byType(HomePlaceholderScreen), findsOneWidget);
    expect(find.byType(AuthScreen), findsNothing);
  });

  testWidgets('no session lands on the auth screen', (tester) async {
    final repo = _FakeAuthRepository(); // no session
    final cubit = buildCubit(repo);
    addTearDown(cubit.close);

    await tester.pumpWidget(_app(cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(HomePlaceholderScreen), findsNothing);
  });

  testWidgets('sign-out from home returns to the auth screen', (tester) async {
    final repo = _FakeAuthRepository(initialSession: _sampleSession());
    final cubit = buildCubit(repo);
    addTearDown(cubit.close);

    await tester.pumpWidget(_app(cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();
    expect(find.byType(HomePlaceholderScreen), findsOneWidget);

    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(HomePlaceholderScreen), findsNothing);
  });
}
