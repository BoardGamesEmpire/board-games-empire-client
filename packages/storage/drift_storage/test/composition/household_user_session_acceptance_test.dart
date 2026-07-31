import 'dart:async';

import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

import '../support/fixed_clock.dart';

/// #135 acceptance, full-stack over the real context + installer + Drift DB:
///
/// 1. A live `watchHouseholds()` subscription across a same-server
///    sign-out → sign-in stops emitting the prior user's data (the stream
///    **closes** when the user-session scope pops — the locked contract).
/// 2. Per-user singletons are rebuilt after a user change: the repository
///    resolved under user B is a different instance, and user A's
///    households are invisible to it.

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
}
