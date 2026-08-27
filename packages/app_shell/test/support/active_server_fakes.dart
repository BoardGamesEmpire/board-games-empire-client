import 'dart:async';

import 'package:di/di.dart';
import 'package:interfaces/orchestration.dart';
import 'package:household/household.dart';
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
  FakeAuthRepository({
    AuthResponse? initialSession,
    this.sessionCheckError,
    this._restorableSession,
  }) : _session = initialSession;

  AuthResponse? _session;

  /// When non-null, [getSession] throws it instead of answering — models
  /// an unreachable server so the shell's #98 offline-restore path can be
  /// driven. Clear it to model connectivity returning.
  Object? sessionCheckError;

  /// When non-null, [restoreCachedSession] adopts it as an
  /// unverified-offline session, mirroring the production contract
  /// (adoption is the point — see the interface docs). Null models a
  /// device with nothing restorable.
  final AuthResponse? _restorableSession;

  AuthState _currentState = const AuthStateUnknown();
  final _controller = StreamController<AuthState>.broadcast();

  @override
  AuthState get currentAuthState => _currentState;

  @override
  Future<AuthResponse?> getSession() async {
    final error = sessionCheckError;
    if (error != null) throw error;
    return _session;
  }

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

  @override
  Future<AuthResponse?> restoreCachedSession() async {
    final restorable = _restorableSession;
    if (restorable == null) return null;
    _session = restorable;
    _setState(
      AuthStateAuthenticated(
        session: restorable,
        verification: SessionVerification.unverifiedOffline,
      ),
    );
    return restorable;
  }

  /// Test seam: drive a repository-level auth transition through the
  /// stream the shell mirrors (e.g. a successful revalidation confirming
  /// an unverified session).
  void emitAuthState(AuthState next) => _setState(next);

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
/// the household deps and the user-session seam), mirroring the production
/// per-server scope the shell reads its dependencies from. Pass the
/// household deps to model a server whose user-session scope is active
/// (native, post-#135/#129); omit them to model web or a signed-out
/// server. Pass [userSessionScope] to observe or script the shell's
/// #135 activate/deactivate wiring; omit it to model a platform without
/// the seam (web until #137).
ActiveServer buildActiveServer(
  AuthRepository repo, {
  HouseholdRepository? householdRepository,
  HouseholdRemoteDataSource? householdRemoteDataSource,
  HouseholdHydrationStatus? householdHydrationStatus,
  HouseholdRefresher? householdRefresher,
  UserSessionScope? userSessionScope,
  SessionRehydrator? sessionRehydrator,
}) {
  final container = DependencyContainerImpl()
    ..registerSingleton<AuthRepository>(repo);
  if (householdHydrationStatus != null) {
    container.registerSingleton<HouseholdHydrationStatus>(
      householdHydrationStatus,
    );
  }
  if (householdRepository != null) {
    container.registerSingleton<HouseholdRepository>(householdRepository);
  }
  if (householdRefresher != null) {
    container.registerSingleton<HouseholdRefresher>(householdRefresher);
  }
  if (householdRemoteDataSource != null) {
    container.registerSingleton<HouseholdRemoteDataSource>(
      householdRemoteDataSource,
    );
  }
  if (userSessionScope != null) {
    container.registerSingleton<UserSessionScope>(userSessionScope);
  }
  if (sessionRehydrator != null) {
    container.registerSingleton<SessionRehydrator>(sessionRehydrator);
  }
  return ActiveServer(
    serverId: 'server-uuid-1',
    displayName: 'My Server',
    identity: serverIdentity(),
    container: container,
  );
}
