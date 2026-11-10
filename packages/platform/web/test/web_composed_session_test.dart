// The browser's session path, driven through the real composition (#369):
// `buildWebServerScope` builds the server scope over the drift/wasm database,
// `WebAuthRepositoryImpl` signs a user in, and `UserSessionScope.activate`
// runs `buildWebUserScopeInstallers()`. Every installer that list ships has
// to have taken effect in the user scope, gone with it when it closes, and
// taken effect again when it reopens.
//
// So this suite proves the bootstrap *wires* the session path: real storage
// over wasm, the real user installer list, real remotes and real auth.
// Only three things are faked: the well-known fetch (a mocked
// `WellKnownClient`), the origin (`https://bge.test.invalid`) and the
// transport (a `ScriptedServer` under the origin scope's `Dio`). That the
// scope *behaves* across users, closing a live stream on sign-out and
// serving the next user only their own rows, is what
// `web_user_session_acceptance_test.dart` proves.
//
// A request no route answers fails the test from a tear-down. Under the
// session a transport error becomes a failed state, not a failed test, so an
// installer sending something unscripted would otherwise pass unseen.
//
// Plain `test()`, not `testWidgets`: drift and the real async work under the
// scope need real time, and the widget tester's fake async would stall them.
//
// Needs `sqlite3.wasm` and `drift_worker.js` beside this file — fetch them
// with `melos run web:assets` (gitignored; #288). Run with
// `melos run test:web`, or `flutter test --platform chrome` in this package.
@TestOn('browser')
library;

import 'package:bge_test_support/network.dart';
import 'package:bge_test_support/waits.dart';
import 'package:dio/dio.dart';
import 'package:drift_storage/drift_storage.dart' show HouseholdRepositoryImpl;
import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:household/household.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:sync_queue/sync_queue.dart';
import 'package:web_platform/web_storage_composition.dart';

import 'support/web_origin.dart';
import 'support/web_session_waits.dart';
import 'support/web_wire_fixtures.dart';

void main() {
  late MockWellKnownClient wellKnownClient;
  late ScriptedServer server;

  setUp(() {
    // Before the tear-down below, which reads it.
    server = ScriptedServer()
      ..json('POST', '/sign-in/email', grantJson())
      ..json('GET', '/get-session', sessionJson())
      ..json('GET', '/api/households', emptyHouseholdPage)
      ..json('GET', '/api/game-collections', emptyCollectionPage)
      ..json('GET', '/api/events', emptyEventPage)
      ..json('GET', '/api/users/me/access', someAccess);

    // Registered first, so that it runs last: tear-downs run in reverse, and
    // this one has to follow the scope's dispose, after which nothing more
    // is sent. Throwing here is what fails the test. Under the session, the
    // `StateError` an unrouted request raises is caught and becomes a failed
    // state, not a failed test.
    addTearDown(() {
      final unrouted = server.unrouted;
      if (unrouted.isEmpty) return;
      throw StateError(
        [
          'No route answered:',
          for (final request in unrouted) '${request.method} ${request.path}',
        ].join('\n'),
      );
    });

    // A fresh server id per test; see `freshIdentity`.
    wellKnownClient = wellKnownAnswering(freshIdentity('web-composed'));
  });

  /// Builds the production web server scope, points its `Dio` at [server],
  /// signs [kWebUserId] in with email and password, and opens their user
  /// scope, as the shell does once the user is signed in. Returns the
  /// scope's container, which resolves from the user scope first and falls
  /// through to the server scope.
  ///
  /// The dispose is registered as soon as the scope exists, so a test that
  /// fails part-way still closes its database and Web Lock before the next
  /// test opens its own.
  Future<DependencyContainer> signIn() async {
    final scope = await buildWebServerScope(
      wellKnownClient: wellKnownClient,
      originProvider: () => kWebTestOrigin,
    );
    addTearDown(() => scope.active!.container.dispose());
    final container = scope.active!.container;
    container.get<Dio>().httpClientAdapter = server;
    await container.get<AuthRepository>().signIn(
      email: 'a@b.c',
      password: 'pw',
    );
    await container.get<UserSessionScope>().activate(kWebUserId);
    return container;
  }

  test('a session fills the household cache over the wasm database', () async {
    server.json('GET', '/api/households', householdPage('hh-1'));
    final container = await signIn();

    // The real repository over the real database: a mocked or in-memory
    // store would pass this for the wrong reason.
    final households = container.get<HouseholdRepository>();
    expect(households, isA<HouseholdRepositoryImpl>());

    final listed = await households
        .watchHouseholds()
        .firstWhere((list) => list.any((h) => h.id == 'hh-1'))
        .timeout(const Duration(seconds: 10));

    expect(listed.map((h) => h.id), contains('hh-1'));
    // So no hydrate is mid-write when the tear-down disposes the scope.
    await awaitHydrated(container);
  });

  /// What each installer `buildWebUserScopeInstallers()` ships registers,
  /// read from [container]. Keyed by the registration and its installer, for
  /// the failure message.
  Map<String, bool Function()> registeredByInstaller(
    DependencyContainer container,
  ) => {
    'SessionRehydrator, by SessionRehydratorInstaller':
        container.isRegistered<SessionRehydrator>,
    'SyncQueueRepository, by UserSessionScopeInstaller':
        container.isRegistered<SyncQueueRepository>,
    'HouseholdRepository, by UserSessionScopeInstaller':
        container.isRegistered<HouseholdRepository>,
    'GameCollectionRepository, by UserSessionScopeInstaller':
        container.isRegistered<GameCollectionRepository>,
    'EventRepository, by UserSessionScopeInstaller':
        container.isRegistered<EventRepository>,
    'HouseholdHydrationStatus, by HouseholdHydrateInstaller':
        container.isRegistered<HouseholdHydrationStatus>,
    'GameCollectionHydrationStatus, by GameCollectionHydrateInstaller':
        container.isRegistered<GameCollectionHydrationStatus>,
    'EventHydrationStatus, by EventHydrateInstaller':
        container.isRegistered<EventHydrationStatus>,
    'CallerAccessRepository, by CallerAccessInstaller':
        container.isRegistered<CallerAccessRepository>,
    'SyncOperationSender, by SyncSenderInstaller':
        container.isRegistered<SyncOperationSender>,
    'SyncQueueDrain, by SyncQueueDrainInstaller':
        container.isRegistered<SyncQueueDrain>,
  };

  test('every installer web ships takes effect at sign-in, in the user '
      'scope', () async {
    final container = await signIn();
    final byInstaller = registeredByInstaller(container);

    for (final MapEntry(key: registration, value: isRegistered)
        in byInstaller.entries) {
      expect(isRegistered(), isTrue, reason: registration);
    }

    // The hydrates send after `activate` returns, so the count waits for
    // each status to land its pass.
    await awaitHydrated(container);

    for (final path in [
      '/api/households',
      '/api/game-collections',
      '/api/events',
    ]) {
      expect(server.requestsTo('GET', path), hasLength(1), reason: path);
    }

    // The container falls through to the server scope, so being registered
    // above does not say which tier registered it. Closing the user scope
    // does: what it held goes with it.
    await container.get<UserSessionScope>().deactivate();

    for (final MapEntry(key: registration, value: isRegistered)
        in byInstaller.entries) {
      expect(
        isRegistered(),
        isFalse,
        reason:
            '$registration outlived the user scope, so the server scope '
            'holds it too (#135)',
      );
    }
  });

  test('the user scope closes and opens again over the shipped '
      'installers', () async {
    // The shell does this at every user change. A teardown that leaves
    // something behind shows on the second open, not the first: a Web Lock
    // still held, a registration still taken, a hydrate that never runs
    // again. The second open is the same user, since another one would need
    // a second session on this origin, and the scope rebuilds all the same.
    final container = await signIn();
    // So no hydrate is mid-write when the scope closes under it.
    await awaitHydrated(container);
    final firstHouseholds = container.get<HouseholdRepository>();
    final session = container.get<UserSessionScope>();

    await session.deactivate();
    await session.activate(kWebUserId);

    for (final MapEntry(key: registration, value: isRegistered)
        in registeredByInstaller(container).entries) {
      expect(isRegistered(), isTrue, reason: '$registration, reopened');
    }
    expect(
      container.get<HouseholdRepository>(),
      isNot(same(firstHouseholds)),
      reason: "the reopened scope reused the closed one's repository",
    );

    await awaitHydrated(container);
    for (final path in [
      '/api/households',
      '/api/game-collections',
      '/api/events',
    ]) {
      expect(
        server.requestsTo('GET', path),
        hasLength(2),
        reason: '$path, once per open',
      );
    }
    // Under the server's Web Lock: a pass that completes here is one the
    // closed scope's drain left the lock for.
    await joinOrRunDrainPass(container);
  });

  test('caller access is asked for once at sign-in, and the answer '
      'kept', () async {
    final container = await signIn();

    await pollUntil(
      () => container.get<CallerAccessRepository>().current.isKnown,
      describe: () =>
          'No caller access answer was kept. Requests: '
          '${server.requests.map((r) => r.path).toList()}',
    );
    // So no hydrate is mid-write when the tear-down disposes the scope.
    await awaitHydrated(container);
    // Then a quiet window, so a second ask sent soon after the first, a
    // re-ask on activation say, has arrived before the count. The ask is
    // started unawaited and reports nothing, so no status or pass settles
    // it: the hydrates land some 20 to 30 ms after the answer, and nothing
    // holds a second ask back until they have. The window runs from after
    // them. A re-ask later than the window, such as the recheck an all-none
    // answer schedules after 2 s, is pinned in the reader's own suite, and
    // `someAccess` keeps it out of this one.
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(server.requestsTo('GET', '/api/users/me/access'), hasLength(1));
  });
}
