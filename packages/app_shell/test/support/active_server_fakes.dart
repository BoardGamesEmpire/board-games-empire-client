import 'dart:async';

import 'package:di/di.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:network_interface/network_interface.dart';

/// Shared fakes for shell widget tests that need a *faithful* post-auth
/// state — one where the bootstrap cubit reports [AppBootstrapReady] AND
/// exposes an active-server scope. That pairing is an invariant of the real
/// cubit (the bootstrap attempt sets the scope before it can emit
/// `NeedsAuth`, and `onAuthenticated` — the only path to `Ready` — fires
/// only from `NeedsAuth`), so a test that drives `Ready` without a scope is
/// exercising a state the app can't actually be in.

const _kAuthBase = '/api/auth';

/// A fake per-server [AuthRepository] with scriptable session state, backing
/// the auth bloc the shell provisions from the active-server scope.
class FakeAuthRepository implements AuthRepository {
  FakeAuthRepository({AuthResponse? initialSession})
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
    _session = sampleSession();
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
    _session = sampleSession();
    _setState(AuthStateAuthenticated(session: _session!));
    return _session!;
  }

  @override
  Future<AuthResponse?> getCachedSession() async => _session;

  // Seed the current state, then pipe subsequent transitions from
  // [_controller] — a detached `Stream.value(...)` would mask
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
class FakeActiveServerScope implements ActiveServerScope {
  FakeActiveServerScope(this._active);
  final ActiveServer _active;

  @override
  ActiveServer? get active => _active;

  @override
  Stream<ActiveServer?> watchActive() => Stream.value(_active);
}

/// A well-formed [ServerIdentity] fixture.
ServerIdentity serverIdentity() => ServerIdentity(
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

/// A restored session fixture.
AuthResponse sampleSession() => AuthResponse(
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

/// An [ActiveServer] whose scoped container carries [repo] (and optionally
/// the per-server household deps), mirroring the production per-server scope
/// the shell reads its dependencies from. Pass the household deps to model a
/// server whose household scope is installed (native, post-#128); omit them
/// to model web or a not-yet-wired native server.
ActiveServer buildActiveServer(
  AuthRepository repo, {
  HouseholdRepository? householdRepository,
  HouseholdRemoteDataSource? householdRemoteDataSource,
}) {
  final container = DependencyContainerImpl()
    ..registerSingleton<AuthRepository>(repo);
  if (householdRepository != null) {
    container.registerSingleton<HouseholdRepository>(householdRepository);
  }
  if (householdRemoteDataSource != null) {
    container.registerSingleton<HouseholdRemoteDataSource>(
      householdRemoteDataSource,
    );
  }
  return ActiveServer(
    serverId: 'server-uuid-1',
    displayName: 'My Server',
    identity: serverIdentity(),
    container: container,
  );
}
