import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:auth/auth.dart';
import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:web_network/web_network.dart';
import 'package:web_platform/web.dart';

/// End-to-end wiring test for the web auth path (#96), tying the two
/// production pieces together through the real shell:
///
/// - the real [WebPlatformBootstrap.initialize] (slice 2), whose injected
///   `serverScopeBuilder` yields
/// - the real [WebActiveServerScope] (slice 1), which the branch-free
///   `BgeApp` auth subtree provisions the auth bloc from.
///
/// The generic "shell provisions the bloc from a web-shaped BootstrapResult"
/// behavior is already covered in `app_shell`
/// (`bge_app_auth_wiring_test.dart`); this test's distinct value is proving
/// the *concrete* web bootstrap + web scope types integrate with the real
/// shell — no `kIsWeb`, no hand-rolled scope stand-in.
///
/// Only the leaf [AuthRepository] is faked, so the auth bloc's startup
/// session check is deterministic and offline. The real
/// `bootstrapWebServerScope` / `registerServerNetworkWeb` / cookie transport
/// are exercised by their own unit tests; here the scope's container simply
/// carries a scriptable session so the gate resolves without a network.
///
/// `AppBootstrapCubit._attempt` calls only `initialize()` on the bootstrap
/// (the hydrated-storage initializer is overridden with a no-op), so the
/// real `WebPlatformBootstrap` never touches `createRootContainer`,
/// `package_info`, or any plugin here.

/// Per-server [AuthRepository] with scriptable session state, backing the
/// auth bloc the shell provisions from the scope. Mirrors the canonical fake
/// in `app_shell`'s auth-wiring test: seed the current state, then pipe
/// subsequent transitions so sign-out/sign-in are observable.
class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository({AuthResponse? initialSession})
    : _session = initialSession;

  AuthResponse? _session;
  AuthState _currentState = const AuthStateUnknown();
  final _controller = StreamController<AuthState>.broadcast();

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

const _kAuthBase = '/api/auth';

ServerIdentity _identity() => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: 'https://bge.example.com',
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

/// Builds the origin [ActiveServer] the way the web path does — a fresh
/// per-server container carrying the (here faked) [AuthRepository].
ActiveServer _activeServer(AuthRepository repo) {
  final container = DependencyContainerImpl()
    ..registerSingleton<AuthRepository>(repo);
  return ActiveServer(
    serverId: 'server-uuid-1',
    displayName: 'Test BGE Server',
    identity: _identity(),
    container: container,
  );
}

void main() {
  Future<void> noopHydrated(PlatformBootstrap _) async {}

  // Real web bootstrap + real WebActiveServerScope; only the AuthRepository
  // inside the scope's container is faked.
  AppBootstrapCubit buildCubit(_FakeAuthRepository repo) => AppBootstrapCubit(
    platformBootstrap: WebPlatformBootstrap(
      serverScopeBuilder: () async => WebActiveServerScope(_activeServer(repo)),
    ),
    hydratedStorageInitializer: noopHydrated,
  );

  testWidgets('the real web bootstrap + WebActiveServerScope drive the shell '
      'to the home placeholder when a session is restored', (tester) async {
    final repo = _FakeAuthRepository(initialSession: _sampleSession());
    final cubit = buildCubit(repo);
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();

    expect(find.byType(HomePlaceholderScreen), findsOneWidget);
    expect(find.byType(AuthScreen), findsNothing);
  });

  testWidgets('… and land on the auth screen when there is no session', (
    tester,
  ) async {
    final repo = _FakeAuthRepository(); // no session
    final cubit = buildCubit(repo);
    addTearDown(cubit.close);

    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await cubit.initialize();
    await tester.pumpAndSettle();

    expect(find.byType(AuthScreen), findsOneWidget);
    expect(find.byType(HomePlaceholderScreen), findsNothing);
  });
}
