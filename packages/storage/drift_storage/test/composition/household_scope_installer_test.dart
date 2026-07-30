import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

import '../support/fixed_clock.dart';

const _kUserId = 'user-abc';
const _kServerId = 'server-uuid-1';
const _kAuthBase = '/api/auth';

/// Minimal [AuthRepository] whose [currentAuthState] is scriptable; only
/// that getter is exercised by the lazy user-id provider (#128), so every
/// other member is intentionally unimplemented.
class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository(this._state);

  AuthState _state;

  /// Flips the scripted auth state so a test can exercise a transition
  /// (e.g. session expiry) under one repository instance — proving the id
  /// is resolved per call, not captured at construction.
  set authState(AuthState next) => _state = next;

  @override
  AuthState get currentAuthState => _state;

  @override
  Future<AuthResponse?> getSession() => throw UnimplementedError();

  @override
  Future<AuthResponse?> getCachedSession() => throw UnimplementedError();

  @override
  Future<void> signOut() => throw UnimplementedError();

  @override
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) => throw UnimplementedError();

  @override
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    required String username,
    String? firstName,
    String? lastName,
  }) => throw UnimplementedError();

  @override
  Stream<AuthState> watchAuthState() => throw UnimplementedError();
}

AuthResponse _session() => AuthResponse(
  token: 'tok',
  user: AuthUser(
    id: _kUserId,
    username: 'tester',
    email: 'tester@example.com',
    emailVerified: true,
    createdAt: DateTime.utc(2024),
    updatedAt: DateTime.utc(2024),
  ),
  expiresAt: DateTime.utc(2099),
);

ServerIdentity _identity() => ServerIdentity(
  serverId: _kServerId,
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
  strategies: const [
    EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '$_kAuthBase/sign-in/email',
      signUpEndpoint: '$_kAuthBase/sign-up/email',
    ),
  ],
);

ServerConfig _config() => ServerConfig(
  id: 'local-1',
  displayName: 'My Server',
  serverUrl: 'https://api.example.com',
  connectionState: ConnectionState.active,
  bgeServerId: _kServerId,
  cachedIdentity: _identity(),
  lastIdentityFetchedAt: DateTime.utc(2024),
);

/// Builds a scope container carrying the three resources the installer
/// resolves — the [ServerDatabase], the [ClockService] and the
/// [AuthRepository] — mirroring what `StorageScopeInstaller` /
/// `registerServerNetwork` register ahead of this installer in production.
DependencyContainer _scopeContainer(AuthRepository auth) {
  final db = ServerDatabase.memory();
  return DependencyContainerImpl()
    ..registerSingleton<ServerDatabase>(db, dispose: (d) => d.close())
    ..registerSingleton<ClockService>(
      FixedClockService(DateTime.utc(2024, 1, 15, 10, 30)),
    )
    ..registerSingleton<AuthRepository>(auth);
}

void main() {
  const installer = HouseholdScopeInstaller();

  test(
    'installs without a session — activation runs before sign-in (#128)',
    () async {
      final container = _scopeContainer(
        _FakeAuthRepository(const AuthStateUnknown()),
      );
      addTearDown(container.dispose);

      // The eager getCachedSession() read this replaces would have thrown
      // here; the lazy provider defers resolution, so install succeeds.
      await installer.install(container, _config());

      expect(container.isRegistered<HouseholdRepository>(), isTrue);
      expect(container.isRegistered<SyncQueueRepository>(), isTrue);
    },
  );

  test(
    'the registered repository resolves the live user id at call time',
    () async {
      final container = _scopeContainer(
        _FakeAuthRepository(AuthStateAuthenticated(session: _session())),
      );
      addTearDown(container.dispose);
      await installer.install(container, _config());

      final repo = container.get<HouseholdRepository>();

      // getHouseholds() reads the provider internally; on the empty DB the
      // authenticated id yields an empty result rather than throwing.
      await expectLater(repo.getHouseholds(), completion(isEmpty));
    },
  );

  test(
    'a household action while unauthenticated throws (programmer error)',
    () async {
      final container = _scopeContainer(
        _FakeAuthRepository(const AuthStateUnauthenticated()),
      );
      addTearDown(container.dispose);
      await installer.install(container, _config());

      final repo = container.get<HouseholdRepository>();

      await expectLater(repo.getHouseholds(), throwsA(isA<StateError>()));
    },
  );

  test('resolves the user id on each call, not once at construction', () async {
    final auth = _FakeAuthRepository(
      AuthStateAuthenticated(session: _session()),
    );
    final container = _scopeContainer(auth);
    addTearDown(container.dispose);
    await installer.install(container, _config());
    final repo = container.get<HouseholdRepository>();

    await expectLater(repo.getHouseholds(), completion(isEmpty));

    // Session expires under the same repository instance; the next call
    // must re-resolve and throw. A regression that captured the id at
    // construction would still succeed here.
    auth.authState = const AuthStateUnauthenticated();
    await expectLater(repo.getHouseholds(), throwsA(isA<StateError>()));
  });

  test(
    'watch* deliver an unauthenticated id as a stream error, not a throw',
    () async {
      final container = _scopeContainer(
        _FakeAuthRepository(const AuthStateUnauthenticated()),
      );
      addTearDown(container.dispose);
      await installer.install(container, _config());
      final repo = container.get<HouseholdRepository>();

      // Invoking the watch methods must not throw synchronously; the
      // StateError has to arrive on the stream so StreamBuilder / .handleError
      // / bloc onError can observe it.
      await expectLater(repo.watchHouseholds(), emitsError(isA<StateError>()));
      await expectLater(
        repo.watchMembers('household-1'),
        emitsError(isA<StateError>()),
      );
    },
  );
}
