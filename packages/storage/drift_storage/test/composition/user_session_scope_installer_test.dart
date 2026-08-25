import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

import '../support/fixed_clock.dart';
import '../support/platform_game_fixture.dart';

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

AuthResponse _session({String userId = _kUserId}) => AuthResponse(
  token: 'tok',
  user: AuthUser(
    id: userId,
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
/// `registerServerNetwork` register in the per-server scope, which the
/// user-scope view falls through to in production (#135).
///
/// Pass [db] to put two sibling user scopes over **one** database — the
/// shared-device shape. The container then does not own the database
/// (the test closes it once, after both scopes are disposed).
DependencyContainer _scopeContainer(AuthRepository auth, {ServerDatabase? db}) {
  final database = db ?? inMemoryServerDatabase();
  return DependencyContainerImpl()
    ..registerSingleton<ServerDatabase>(
      database,
      dispose: db == null ? (d) => d.close() : null,
    )
    ..registerSingleton<ClockService>(
      FixedClockService(DateTime.utc(2024, 1, 15, 10, 30)),
    )
    ..registerSingleton<AuthRepository>(auth);
}

/// Two installed user scopes for different users over one database, with
/// teardown wired. Returns them in install order (A, then B).
Future<({DependencyContainer a, DependencyContainer b})> _siblingScopes(
  AuthRepository auth,
  ServerDatabase db, {
  required String userA,
  required String userB,
}) async {
  const installer = UserSessionScopeInstaller();
  final scopeA = _scopeContainer(auth, db: db);
  final scopeB = _scopeContainer(auth, db: db);
  addTearDown(() async {
    await scopeA.dispose();
    await scopeB.dispose();
    await db.close();
  });

  await installer.install(scopeA, _config(), userA);
  await installer.install(scopeB, _config(), userB);
  return (a: scopeA, b: scopeB);
}

void main() {
  const installer = UserSessionScopeInstaller();

  test('install never reads the auth state itself — resolution stays lazy '
      '(#128), so it succeeds under an unknown state', () async {
    final container = _scopeContainer(
      _FakeAuthRepository(const AuthStateUnknown()),
    );
    addTearDown(container.dispose);

    // An eager session read would throw here; the lazy provider defers
    // resolution, so install succeeds regardless of the live auth state.
    await installer.install(container, _config(), _kUserId);

    expect(container.isRegistered<HouseholdRepository>(), isTrue);
    expect(container.isRegistered<SyncQueueRepository>(), isTrue);
    expect(container.isRegistered<GameCollectionRepository>(), isTrue);
  });

  test(
    'the registered repository resolves the live user id at call time',
    () async {
      final container = _scopeContainer(
        _FakeAuthRepository(AuthStateAuthenticated(session: _session())),
      );
      addTearDown(container.dispose);
      await installer.install(container, _config(), _kUserId);

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
      await installer.install(container, _config(), _kUserId);

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
    await installer.install(container, _config(), _kUserId);
    final repo = container.get<HouseholdRepository>();

    await expectLater(repo.getHouseholds(), completion(isEmpty));

    // Session expires under the same repository instance; the next call
    // must re-resolve and throw. A regression that captured the id at
    // construction would still succeed here.
    auth.authState = const AuthStateUnauthenticated();
    await expectLater(repo.getHouseholds(), throwsA(isA<StateError>()));
  });

  test(
    'an authenticated user who is not the scope user throws — a missed '
    'scope pop must fail loudly, never serve cross-user data (#135)',
    () async {
      final auth = _FakeAuthRepository(
        AuthStateAuthenticated(session: _session()),
      );
      final container = _scopeContainer(auth);
      addTearDown(container.dispose);
      await installer.install(container, _config(), _kUserId);
      final repo = container.get<HouseholdRepository>();

      // A different user authenticates while the old user scope is somehow
      // still live (the shell failed to pop it).
      auth.authState = AuthStateAuthenticated(
        session: _session(userId: 'user-someone-else'),
      );

      await expectLater(repo.getHouseholds(), throwsA(isA<StateError>()));
    },
  );

  test(
    'watch* deliver an unauthenticated id as a stream error, not a throw',
    () async {
      final container = _scopeContainer(
        _FakeAuthRepository(const AuthStateUnauthenticated()),
      );
      addTearDown(container.dispose);
      await installer.install(container, _config(), _kUserId);
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

  test('disposing the container closes a live watch stream — the dispose '
      'wiring behind close-on-scope-pop (#135)', () async {
    final container = _scopeContainer(
      _FakeAuthRepository(AuthStateAuthenticated(session: _session())),
    );
    await installer.install(container, _config(), _kUserId);
    final repo = container.get<HouseholdRepository>();

    var done = false;
    final sub = repo.watchHouseholds().listen(
      (_) {},
      onDone: () => done = true,
    );
    addTearDown(sub.cancel);
    await pumpEventQueue();
    expect(done, isFalse);

    await container.dispose();
    await pumpEventQueue();

    expect(done, isTrue);
  });

  test('disposing the container closes a live sync-queue count stream — '
      'the #138 close-on-scope-pop wiring for the queue', () async {
    final container = _scopeContainer(
      _FakeAuthRepository(AuthStateAuthenticated(session: _session())),
    );
    await installer.install(container, _config(), _kUserId);
    final queue = container.get<SyncQueueRepository>();

    var done = false;
    final sub = queue.watchPendingCount().listen(
      (_) {},
      onDone: () => done = true,
    );
    addTearDown(sub.cancel);
    await pumpEventQueue();
    expect(done, isFalse);

    await container.dispose();
    await pumpEventQueue();

    expect(done, isTrue);
  });

  test(
    'the registered sync queue is data-scoped to the install user id '
    '(#147): a sibling scope for another user sees none of its rows',
    () async {
      final auth = _FakeAuthRepository(
        AuthStateAuthenticated(session: _session()),
      );
      // Two user scopes over the SAME database — the shared-device shape.
      final db = inMemoryServerDatabase();
      final (a: scopeA, b: scopeB) = await _siblingScopes(
        auth,
        db,
        userA: _kUserId,
        userB: 'user-someone-else',
      );

      final queueA = scopeA.get<SyncQueueRepository>();
      await queueA.enqueue(
        const CreateHouseholdOperation(localId: 'hh-1', name: 'HQ'),
      );

      expect(await queueA.getPendingCount(), 1);
      expect(
        await scopeB.get<SyncQueueRepository>().getPendingCount(),
        0,
        reason: '#147: another user\'s scope must not see the rows',
      );
    },
  );

  test(
    'disposing the container closes a live collection stream — the #138 '
    'close-on-scope-pop wiring for the collection repository (#150)',
    () async {
      final container = _scopeContainer(
        _FakeAuthRepository(AuthStateAuthenticated(session: _session())),
      );
      await installer.install(container, _config(), _kUserId);
      final collections = container.get<GameCollectionRepository>();

      var done = false;
      Object? streamError;
      final sub = collections.watchCollection().listen(
        (_) {},
        onError: (Object e) => streamError = e,
        onDone: () => done = true,
      );
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(done, isFalse);

      await container.dispose();
      await pumpEventQueue();

      expect(done, isTrue, reason: 'the dispose: callback must be wired');
      expect(streamError, isNull, reason: 'close, not error');
    },
  );

  test(
    'the registered collection repository rejects reads after the scope pops '
    '(#150): a stale reference cannot serve the departed user',
    () async {
      final container = _scopeContainer(
        _FakeAuthRepository(AuthStateAuthenticated(session: _session())),
      );
      await installer.install(container, _config(), _kUserId);
      final collections = container.get<GameCollectionRepository>();

      await expectLater(collections.getCollection(), completion(isEmpty));

      await container.dispose();

      await expectLater(collections.getCollection(), throwsStateError);
    },
  );

  test(
    'the registered collection repository is data-scoped to the install user '
    'id: a sibling scope for another user sees none of its rows (#150)',
    () async {
      final auth = _FakeAuthRepository(
        AuthStateAuthenticated(session: _session()),
      );
      // Two user scopes over the SAME database — the shared-device shape.
      // The repository already filters on userId; this pins the *wiring*,
      // proving the installer hands each scope its own user's id.
      final db = inMemoryServerDatabase();
      final (a: scopeA, b: scopeB) = await _siblingScopes(
        auth,
        db,
        userA: _kUserId,
        userB: 'user-someone-else',
      );

      await seedPlatformGame(db);

      final collectionsA = scopeA.get<GameCollectionRepository>();
      final added = await collectionsA.addToCollection(
        platformGameId: kFixturePlatformGameId,
        medium: GameMedium.physical,
      );
      expect(added.userId, _kUserId);

      expect(await collectionsA.getCollection(), hasLength(1));
      expect(
        await scopeB.get<GameCollectionRepository>().getCollection(),
        isEmpty,
        reason: "another user's scope must not see the rows",
      );
      // End-to-end through the container: B cannot observe A's row by id
      // either, and B's live stream never carries it.
      await expectLater(
        scopeB.get<GameCollectionRepository>().watchEntry(added.id).first,
        completion(isNull),
      );
    },
  );

  test(
    'the collection repository enqueues through the same scope\'s sync queue '
    '— one user session, one outbound queue (#147)',
    () async {
      final container = _scopeContainer(
        _FakeAuthRepository(AuthStateAuthenticated(session: _session())),
      );
      addTearDown(container.dispose);
      await installer.install(container, _config(), _kUserId);
      await seedPlatformGame(container.get<ServerDatabase>());

      await container.get<GameCollectionRepository>().addToCollection(
        platformGameId: kFixturePlatformGameId,
        medium: GameMedium.physical,
      );

      expect(
        await container.get<SyncQueueRepository>().getPendingCount(),
        1,
        reason: 'the add must be queued for the drain worker (#121)',
      );
    },
  );
}
