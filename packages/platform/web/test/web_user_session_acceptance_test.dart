// #137's acceptance criterion, executed rather than inspected: a same-origin
// sign-out → sign-in rebuilds the per-user singletons, and a live `watch*`
// subscription across the transition stops emitting the prior user's data.
//
// Browser-only and full-stack on purpose. The native equivalent
// (`drift_storage/test/composition/user_session_acceptance_test.dart`) runs on
// the VM over an in-memory database; web cannot, because
// `inMemoryServerDatabase` lives in `drift_storage_native.dart` and the
// drift/wasm executor reaches `dart:js_interop`. So this is the only place
// the web path can be proved end to end, over a real database.
//
// What it composes is what production composes — the `WebServerScopeContainer`
// facade, a `UserScopeHost`, `ContainerUserSessionScope`, and the *shared*
// `UserSessionScopeInstaller`, wired together in the same order and with the
// same arguments as `bootstrapWebServerScope`. It does not go *through* that
// function: it registers a fake `AuthRepository`, which the real bootstrap
// would already have filled with `WebAuthRepositoryImpl` over a real `Dio`,
// and the installer reads `currentAuthState` to resolve the session's user —
// the same reason native's equivalent fakes it.
//
// So this suite proves the *scope behaves*, not that the bootstrap *wires it*.
// The wiring — the well-known fetch, the real Dio, and which arguments
// `bootstrapWebServerScope` actually passes — is pinned on the VM by
// `web_network/test/orchestration/bootstrap_web_server_scope_test.dart`.
// Keep the assembly below matching that function; a divergence here weakens
// the parity this file claims without failing anything.
//
// Needs `sqlite3.wasm` and `drift_worker.js` beside this file — fetch them
// with `melos run web:assets` (gitignored; #288). Run with
// `melos run test:web`, or `flutter test --platform chrome` in this package.
@TestOn('browser')
library;

import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';
import 'package:web_network/web_network.dart';
import 'package:web_storage/web_storage.dart';

const _kUserA = 'user-a';
const _kUserB = 'user-b';

const _server = ScopedServer(
  serverId: 'server-uuid-web-1',
  displayName: 'Origin',
);

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

AuthState _authenticated(String userId) => AuthStateAuthenticated(
  session: AuthResponse(
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
  ),
);

/// Frozen clock. Web's real one is the skew-corrected estimator from #118,
/// registered in the origin scope; the installers only ever read `nowUtc`.
class _FixedClock implements ClockService {
  const _FixedClock(this._now);
  final DateTime _now;

  @override
  DateTime nowUtc() => _now;

  @override
  Duration? get skewEstimate => null;

  @override
  Stream<Duration?> watchSkew() => Stream<Duration?>.multi((controller) {
    controller
      ..add(null)
      ..close();
  });
}

void main() {
  late _FakeAuthRepository auth;
  late DependencyContainerImpl origin;
  late UserScopeHost host;
  late WebServerScopeContainer container;
  late ContainerUserSessionScope session;
  late ServerDatabase database;

  setUp(() async {
    auth = _FakeAuthRepository(const AuthStateUnknown());

    // A fresh database name per test: the browser's IndexedDB outlives the
    // test that opened it, so a shared name would leak rows between tests.
    final opening = await const WebWasmExecutorFactory().serverDatabase(
      'web-session-${DateTime.now().microsecondsSinceEpoch}',
    );
    database = ServerDatabase(opening.executor, enableWriteAheadLog: false);

    // The origin scope, as `registerServerNetworkWeb` + `WebStorageInstaller`
    // leave it: the database, the clock, and the auth repository — all of
    // which the user-scope installers resolve by falling through.
    origin = DependencyContainerImpl()
      ..registerSingleton<ServerDatabase>(database, dispose: (db) => db.close())
      ..registerSingleton<ClockService>(
        _FixedClock(DateTime.utc(2026, 8, 29, 10, 30)),
      )
      ..registerSingleton<AuthRepository>(auth);

    // Assembled in `bootstrapWebServerScope`'s order, and for its reason:
    // the holder exists before the container so the container's teardown
    // can be routed through the holder's serialization chain (`closeSession`)
    // rather than closing the host behind it. Constructing it without that
    // argument would take a branch production never takes.
    host = UserScopeHost(parent: () => origin);
    session = ContainerUserSessionScope(
      host: host,
      installers: const [UserSessionScopeInstaller()],
      server: _server,
    );
    container = WebServerScopeContainer(
      base: origin,
      host: host,
      closeSession: session.dispose,
    );
    container.registerSingleton<UserSessionScope>(
      session,
      dispose: (_) => session.dispose(),
    );
  });

  tearDown(() => container.dispose());

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
    // Resolved through the facade, exactly as the shell's routes do.
    final repoA = container.get<HouseholdRepository>();
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

    // Acceptance criterion 1: the scope pop CLOSES the live stream rather
    // than erroring it — the contract locked on #135.
    await signOut();
    await pumpEventQueue();

    expect(done, isTrue, reason: 'scope pop must close vended streams');
    expect(errors, isEmpty, reason: 'close-on-pop, never error-on-pop');
    expect(
      emissions.length,
      countBeforeSignOut,
      reason: 'no further data after the pop',
    );

    // Acceptance criterion 2: per-user singletons are rebuilt.
    await signIn(_kUserB);
    final repoB = container.get<HouseholdRepository>();
    expect(identical(repoA, repoB), isFalse);

    // The origin-scoped database still holds user A's rows; the membership
    // read gate hides them from user B.
    await expectLater(repoB.watchHouseholds().first, completion(isEmpty));
    await expectLater(repoB.getHouseholds(), completion(isEmpty));
  });

  test('the per-user tier is unreachable until a session is active', () async {
    // The reason web needed a container facade at all: before a sign-in
    // there is nothing to resolve, and the shell's routes gate on exactly
    // this answer.
    expect(container.isRegistered<HouseholdRepository>(), isFalse);
    expect(container.isRegistered<SyncQueueRepository>(), isFalse);
    expect(container.isRegistered<GameCollectionRepository>(), isFalse);

    await signIn(_kUserA);

    expect(container.isRegistered<HouseholdRepository>(), isTrue);
    expect(container.isRegistered<SyncQueueRepository>(), isTrue);
    expect(container.isRegistered<GameCollectionRepository>(), isTrue);

    await signOut();

    expect(container.isRegistered<HouseholdRepository>(), isFalse);
  });

  test('the origin scope survives a session, database included', () async {
    await signIn(_kUserA);
    await container.get<HouseholdRepository>().create(name: 'Alpha');

    await signOut();

    // The database is the origin scope's, not the session's — a sign-out
    // must not close it, or the next sign-in has nothing to open.
    expect(container.get<ServerDatabase>(), same(database));
    await signIn(_kUserA);
    await expectLater(
      container.get<HouseholdRepository>().getHouseholds(),
      completion(hasLength(1)),
    );
  });

  test('the disposed repository fails loudly instead of serving the '
      'departed user', () async {
    await signIn(_kUserA);
    final repoA = container.get<HouseholdRepository>();
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
}
