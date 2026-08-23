import 'dart:async';

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

/// User-session scope acceptance (#135, extended by #150), full-stack over
/// the real context + installer + Drift DB:
///
/// 1. A live `watchHouseholds()` subscription across a same-server
///    sign-out → sign-in stops emitting the prior user's data (the stream
///    **closes** when the user-session scope pops — the locked contract).
/// 2. Per-user singletons are rebuilt after a user change: the repository
///    resolved under user B is a different instance, and user A's
///    households are invisible to it.
///
/// #150 extends both to `GameCollectionRepository`, which joined the same
/// scope, and adds the missed-pop case: a *direct* user change with no
/// intervening sign-out.

const _kUserA = 'user-a';
const _kUserB = 'user-b';
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

AuthState _authenticated(String userId) =>
    AuthStateAuthenticated(session: _session(userId));

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

/// Registers the three per-server resources the household installer
/// resolves, mirroring what `StorageScopeInstaller` / `registerServerNetwork`
/// register ahead of any user session in production.
class _BaseFixtureInstaller implements ServerScopeInstaller {
  _BaseFixtureInstaller(this._auth);
  final AuthRepository _auth;

  @override
  Future<void> install(
    DependencyContainer container,
    ServerConfig config,
  ) async {
    container.registerSingleton<ServerDatabase>(
      inMemoryServerDatabase(),
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
      userInstallers: const [UserSessionScopeInstaller()],
    );
    await context.activate();
    session = context.container.get<UserSessionScope>();
  });

  tearDown(() => context.dispose());

  Future<void> signIn(String userId) async {
    auth.authState = _authenticated(userId);
    await session.activate(userId);
  }

  Future<void> signOut() async {
    auth.authState = const AuthStateUnauthenticated();
    await session.deactivate();
  }

  test('a live watchHouseholds subscription closes on sign-out and the '
      'rebuilt scope serves only the new user\'s data', () async {
    await signIn(_kUserA);
    final repoA = context.container.get<HouseholdRepository>();
    await repoA.create(name: 'Alpha Household');

    final emissions = <List<Household>>[];
    final errors = <Object>[];
    var done = false;
    final sub = repoA.watchHouseholds().listen(
      emissions.add,
      onError: errors.add,
      onDone: () => done = true,
    );
    addTearDown(sub.cancel);

    await pumpEventQueue();
    expect(emissions, isNotEmpty);
    expect(emissions.last.single.name, 'Alpha Household');
    final countBeforeSignOut = emissions.length;

    // Same-server sign-out: the scope pop must CLOSE the live stream
    // (not error it) — acceptance criterion 1.
    await signOut();
    await pumpEventQueue();

    expect(done, isTrue, reason: 'scope pop must close vended streams');
    expect(errors, isEmpty, reason: 'close-on-pop, never error-on-pop');
    expect(
      emissions.length,
      countBeforeSignOut,
      reason: 'no further data after the pop',
    );

    // Same-server sign-in as a different user: per-user singletons are
    // rebuilt — acceptance criterion 2.
    await signIn(_kUserB);
    final repoB = context.container.get<HouseholdRepository>();
    expect(identical(repoA, repoB), isFalse);

    // The shared per-server DB still holds user A's rows, but the
    // membership read gate hides them from user B.
    await expectLater(repoB.watchHouseholds().first, completion(isEmpty));
    await expectLater(repoB.getHouseholds(), completion(isEmpty));
  });

  test('the disposed repository fails loudly instead of serving the '
      'departed user', () async {
    await signIn(_kUserA);
    final repoA = context.container.get<HouseholdRepository>();
    await repoA.create(name: 'Alpha Household');

    await signOut();

    await expectLater(repoA.getHouseholds(), throwsA(isA<StateError>()));
    await expectLater(
      repoA.create(name: 'Too Late'),
      throwsA(isA<StateError>()),
    );
    // A fresh watch on the disposed instance closes immediately.
    await expectLater(repoA.watchHouseholds(), emitsDone);
  });

  test('watchMembers subscriptions close on sign-out too', () async {
    await signIn(_kUserA);
    final repoA = context.container.get<HouseholdRepository>();
    final created = await repoA.create(name: 'Alpha Household');

    var done = false;
    final sub = repoA
        .watchMembers(created.household.id)
        .listen((_) {}, onDone: () => done = true);
    addTearDown(sub.cancel);
    await pumpEventQueue();

    await signOut();
    await pumpEventQueue();

    expect(done, isTrue);
  });

  test('per-server services survive the session pop', () async {
    await signIn(_kUserA);
    await signOut();

    // The base scope is untouched: the DB and the session seam remain
    // registered and usable for the next sign-in.
    expect(context.container.isRegistered<ServerDatabase>(), isTrue);
    expect(context.container.isRegistered<UserSessionScope>(), isTrue);
    expect(context.container.isRegistered<HouseholdRepository>(), isFalse);

    await signIn(_kUserB);
    expect(context.container.isRegistered<HouseholdRepository>(), isTrue);
  });

  test('a live watchCollection subscription closes on sign-out and the '
      'rebuilt scope serves only the new user\'s collection (#150)', () async {
    await signIn(_kUserA);
    await seedPlatformGame(context.container.get<ServerDatabase>());
    final collectionsA = context.container.get<GameCollectionRepository>();
    await collectionsA.addToCollection(
      platformGameId: kFixturePlatformGameId,
      medium: GameMedium.physical,
    );

    final emissions = <List<GameCollection>>[];
    final errors = <Object>[];
    var done = false;
    final sub = collectionsA.watchCollection().listen(
      emissions.add,
      onError: errors.add,
      onDone: () => done = true,
    );
    addTearDown(sub.cancel);
    await pumpEventQueue();
    expect(emissions.last, hasLength(1));
    final countBeforeSignOut = emissions.length;

    await signOut();
    await pumpEventQueue();

    expect(done, isTrue, reason: 'scope pop must close vended streams');
    expect(errors, isEmpty, reason: 'close-on-pop, never error-on-pop');
    expect(emissions.length, countBeforeSignOut);

    await signIn(_kUserB);
    final collectionsB = context.container.get<GameCollectionRepository>();
    expect(identical(collectionsA, collectionsB), isFalse);

    // The row is still in the shared per-server table; user B's scope
    // must not see it. This pins the *wiring* — the repository's own
    // userId filter is covered in its unit tests.
    await expectLater(collectionsB.getCollection(), completion(isEmpty));
    await expectLater(
      collectionsB.watchCollection().first,
      completion(isEmpty),
    );
  });

  test('the disposed collection repository fails loudly instead of writing '
      'for the departed user (#150)', () async {
    await signIn(_kUserA);
    // No platform-game seed: every call below throws from
    // checkNotDisposed() before any SQL runs, so there is no FK to satisfy.
    final collectionsA = context.container.get<GameCollectionRepository>();

    await signOut();

    await expectLater(collectionsA.getCollection(), throwsA(isA<StateError>()));
    await expectLater(
      collectionsA.addToCollection(
        platformGameId: kFixturePlatformGameId,
        medium: GameMedium.physical,
      ),
      throwsA(isA<StateError>()),
    );
    await expectLater(collectionsA.watchCollection(), emitsDone);
  });

  test('a direct user change with no intervening sign-out still disposes the '
      'departing user\'s collection repository — a missed pop cannot serve '
      'cross-user data (#150)', () async {
    await signIn(_kUserA);
    await seedPlatformGame(context.container.get<ServerDatabase>());
    final collectionsA = context.container.get<GameCollectionRepository>();
    await collectionsA.addToCollection(
      platformGameId: kFixturePlatformGameId,
      medium: GameMedium.physical,
    );

    // No signOut(): user B activates straight over user A's live
    // session. The context tears the previous scope down defensively,
    // which is what keeps the fixed-at-construction user id safe — a
    // stale reference cannot outlive the user it was built for.
    auth.authState = _authenticated(_kUserB);
    await session.activate(_kUserB);

    await expectLater(
      collectionsA.getCollection(),
      throwsA(isA<StateError>()),
      reason: "user A's instance is disposed, not silently reused",
    );
    await expectLater(
      context.container.get<GameCollectionRepository>().getCollection(),
      completion(isEmpty),
      reason: "user B resolves a fresh instance scoped to B",
    );
  });
}
