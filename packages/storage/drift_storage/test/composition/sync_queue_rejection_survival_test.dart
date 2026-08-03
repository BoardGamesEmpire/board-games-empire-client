import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

import '../support/fixed_clock.dart';

/// #98 (locked decision D8): writes queued under an optimistic offline
/// session survive that session's rejection.
///
/// The scenario: a user enters on a cached session (#98), queues writes
/// while offline, reconnects, and revalidation returns 401 — the session
/// is genuinely gone. The repository clears the token, the shell pops the
/// user-session scope (#135), and the user lands on the sign-in form. D8
/// locks that the queued writes are NOT discarded in that teardown,
/// consistent with the standing "permanent server rejections stay queued"
/// rule: the rejection was of the SESSION, not of the work.
///
/// Mechanically, survival rests on the queue's storage being per-server
/// while the repository OBJECT over it is per-user: the scope pop disposes
/// the `SyncQueueRepositoryImpl` instance, but the rows live in the
/// server-scoped `ServerDatabase`, which the pop does not touch. This test
/// pins that as a contract rather than an accident of wiring — if queue
/// rows ever move into per-user storage or a teardown path gains a
/// delete, this is the test that must be consciously revisited.
///
/// Since #147 the rows are additionally **data-scoped to the enqueuing
/// user**: each carries a `user_id` and every repository read/write
/// filters on it. Survival and scoping now compose: a departed user's
/// rows persist in the table (this test) but are invisible to any other
/// user's session scope, and drainable only when the SAME user returns —
/// which is why the re-sign-in below is user A. The cross-user
/// visibility/drain hazard this suite once carried a warning about is
/// closed in the data model; its dedicated coverage lives in
/// `../repositories/sync_queue_user_scoping_test.dart`.
const _kUserA = 'user-a';
const _kServerId = 'server-uuid-1';
const _kAuthBase = '/api/auth';

class _FakeAuthRepository implements AuthRepository {
  _FakeAuthRepository(this._state);

  AuthState _state;

  set authState(AuthState next) => _state = next;

  @override
  AuthState get currentAuthState => _state;

  @override
  Future<AuthResponse?> getSession() => throw UnimplementedError();

  @override
  Future<AuthResponse?> getCachedSession() => throw UnimplementedError();

  @override
  Future<AuthResponse?> restoreCachedSession() => throw UnimplementedError();

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

AuthResponse _session(String userId) => AuthResponse(
  token: 'tok-$userId',
  user: AuthUser(
    id: userId,
    username: 'tester-$userId',
    email: '$userId@example.com',
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

class _BaseFixtureInstaller implements ServerScopeInstaller {
  _BaseFixtureInstaller(this._auth);
  final AuthRepository _auth;

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    container.registerSingleton<ServerDatabase>(
      ServerDatabase.memory(),
      dispose: (db) => db.close(),
    );
    container.registerSingleton<ClockService>(
      FixedClockService(DateTime.utc(2024, 1, 15, 10, 30)),
    );
    container.registerSingleton<AuthRepository>(_auth);
  }
}

void main() {
  late _FakeAuthRepository auth;
  late ServerContextImpl context;
  late UserSessionScope session;

  setUp(() async {
    auth = _FakeAuthRepository(const AuthStateUnknown());
    context = ServerContextImpl(
      config: _config(),
      installers: [_BaseFixtureInstaller(auth)],
      userInstallers: const [HouseholdScopeInstaller()],
    );
    await context.activate();
    session = context.container.get<UserSessionScope>();
  });

  tearDown(() => context.dispose());

  /// The #98 entry: the shell activates the user scope on the session the
  /// repository adopted from local material, before any server round trip.
  Future<void> enterOptimistically(String userId) async {
    auth.authState = AuthStateAuthenticated(
      session: _session(userId),
      verification: SessionVerification.unverifiedOffline,
    );
    await session.activate(userId);
  }

  /// The rejection: revalidation 401s, the repository clears and settles
  /// unauthenticated, and the shell's exit listener pops the user scope —
  /// the exact teardown `_AuthScope` runs.
  Future<void> sessionRejected() async {
    auth.authState = const AuthStateUnauthenticated();
    await session.deactivate();
  }

  test('writes queued under an unverified session survive its rejection '
      'and are drainable after the same user signs back in (D8)', () async {
    await enterOptimistically(_kUserA);

    // Queue an offline write the way the household bloc does: through the
    // per-user repository's create path, which enqueues the sync op.
    final repoA = context.container.get<HouseholdRepository>();
    final created = await repoA.create(name: 'Offline Household');
    expect(created.syncQueueId, isNotEmpty);

    final queueA = context.container.get<SyncQueueRepository>();
    expect(await queueA.getPendingCount(), 1);

    // Reconnect; the server rejects the optimistic session.
    await sessionRejected();

    // The per-user repository OBJECT is gone with the scope...
    expect(context.container.isRegistered<SyncQueueRepository>(), isFalse);

    // ...but the rows are not: read the server-scoped table directly. The
    // rejection was of the session, not of the work — nothing in the
    // teardown may delete it.
    final db = context.container.get<ServerDatabase>();
    final surviving = await db.select(db.syncQueueTable).get();
    expect(surviving, hasLength(1), reason: 'D8: rejection never discards');

    // The same user signs back in (a real credential grant this time); the
    // rebuilt scope sees the queued write as pending, ready for the drain
    // worker (#121) to pick up.
    auth.authState = AuthStateAuthenticated(session: _session(_kUserA));
    await session.activate(_kUserA);

    final queueAfter = context.container.get<SyncQueueRepository>();
    expect(await queueAfter.getPendingCount(), 1);
    final pending = await queueAfter.getPendingEntries();
    expect(pending.single.id, created.syncQueueId);
  });

  test('a rejected session with an EMPTY queue tears down clean — nothing '
      'left behind to drain', () async {
    await enterOptimistically(_kUserA);
    await sessionRejected();

    final db = context.container.get<ServerDatabase>();
    expect(await db.select(db.syncQueueTable).get(), isEmpty);
  });
}
