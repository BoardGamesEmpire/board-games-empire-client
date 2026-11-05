// Four situations run through the real native root (#435): a sign-out while
// a hydrate is in flight (#433), a create whose answer is lost (#131), a
// restart with work still queued (#121, #142), and a server backgrounded
// between a send and its acknowledgement (#121). Each rule already has a
// twin over hand-built collaborators: the sign-out wire test in
// `dio_network`, and the sender and drain suites in `sync_queue`. Those pin
// the rules. These pin that the composition the root ships keeps each of
// them in the situation its test sets up, over its own interceptors, token
// storage, scopes and installers, and its server context's lifecycle. Where
// a rule guards a race this situation does not reach, the twin stays the
// only pin; the sign-out test says which. The backgrounding test says why it
// drives the context rather than the orchestrator.
//
// Plain `test()`, not `testWidgets`: drift and the real async work under the
// root need real time, and the widget tester's fake async would stall them.

import 'dart:async';

import 'package:bge_test_support/network.dart';
import 'package:bge_test_support/waits.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:sync_queue/sync_queue.dart';

import 'support/native_root_harness.dart';

// `dio_network/test/household/household_remote_data_source_impl_test.dart`
// (`_createEnvelope(_householdJson())`), under the id `hh-server` and the
// name the create sends, cut to the fields `HouseholdRemoteDataSourceImpl`
// requires.
const _createAnswer = {
  'household': {
    'id': 'hh-server',
    'name': 'Game night',
    'createdAt': '2026-01-15T10:30:00.000Z',
    'updatedAt': '2026-01-15T10:30:00.000Z',
  },
};

void main() {
  group('the native root (#435)', () {
    late NativeRootHarness harness;

    HouseholdRepository householdRepository() =>
        harness.container.get<HouseholdRepository>();
    SyncQueueRepository queue() => harness.container.get<SyncQueueRepository>();
    SyncQueueDrain drain() => harness.container.get<SyncQueueDrain>();

    List<RecordedRequest> creates() =>
        harness.server.requestsTo('POST', '/api/households');

    Future<List<String>> householdIds() async =>
        (await householdRepository().getHouseholds()).map((h) => h.id).toList();

    setUp(() async {
      harness = await NativeRootHarness.create();
      addTearDown(harness.dispose);
      await harness.boot();
      await harness.addServer();
      await harness.signIn();
    });

    /// Opens the user scope and waits for what it starts: the hydrates, and
    /// the drain's first pass, which finds the queue empty.
    Future<void> activated() async {
      await harness.activateUser();
      await harness.awaitHydrated();
      await harness.joinOrRunDrainPass();
    }

    /// Holds the household page, opens the user scope, and returns once the
    /// hydrate has asked for the page, with the completer that releases it.
    Future<Completer<ScriptedResponse>> householdPageHeld() async {
      final release = Completer<ScriptedResponse>();
      addTearDown(() {
        if (!release.isCompleted) {
          release.complete(ScriptedResponse.json(const <String, Object?>{}));
        }
      });
      harness.server
        ..hold('GET', '/api/households', release.future)
        ..clear();
      await harness.activateUser();
      await harness.awaitRequests('GET', '/api/households');
      return release;
    }

    /// Releases [held] with the one-household page, then waits twenty
    /// zero-delay turns ([pumpEventQueue]).
    ///
    /// The sign-out test asserts that the page writes nothing within this
    /// wait, which proves nothing unless the page would have landed within
    /// it. The control test after it shows that it does, while the session
    /// is kept, so a write slowed past the wait fails the control instead
    /// of passing the sign-out test.
    Future<void> releasePageAndSettle(Completer<ScriptedResponse> held) async {
      held.complete(
        ScriptedResponse.json(NativeRootHarness.householdPageWithOne),
      );
      await pumpEventQueue();
    }

    Future<List<String>> cachedHouseholdRows() async {
      final db = harness.container.get<ServerDatabase>();
      return [
        for (final row in await db.select(db.householdsTable).get()) row.id,
      ];
    }

    test('sign-out while a hydrate is in flight sends the departing token '
        'and writes nothing for the departed user (#433)', () async {
      final held = await householdPageHeld();

      // The shell's order: the auth state turning unauthenticated is what
      // pops the user scope, in the `AuthUnauthenticated` arm of the auth
      // listener in `packages/app_shell/lib/src/widgets/bge_app.dart`, which
      // calls `_deactivateSessionScope`.
      //
      // This pins the departing token on the wire through the root's own
      // stack, in that order, and that a page arriving after the session
      // ended writes nothing. It does not pin #433's race, a token stored
      // between `TokenStorageService.clear()` and the interceptor's read:
      // nothing here stores one, so this passes with the fix reverted.
      // `dio_network/test/auth/auth_repository_sign_out_wire_test.dart`
      // pins that.
      await harness.container.get<AuthRepository>().signOut();
      await harness.container.get<UserSessionScope>().deactivate();
      await releasePageAndSettle(held);

      expect(
        harness.server.requestsTo('POST', '/sign-out').single.authorization,
        'Bearer ${NativeRootHarness.sessionToken}',
      );
      expect(
        await cachedHouseholdRows(),
        isEmpty,
        reason: 'the page came back after the session ended',
      );
      expect(harness.container.isRegistered<HouseholdRepository>(), isFalse);
    });

    test('the same page, released while the session is kept, is cached '
        'within the same wait (the control for #433)', () async {
      final held = await householdPageHeld();

      await releasePageAndSettle(held);

      expect(await cachedHouseholdRows(), [NativeRootHarness.householdId]);
    });

    test('a create whose answer is lost is sent again under the same key, '
        'and lands once (#131)', () async {
      await activated();
      harness.server
        ..drop('POST', '/api/households')
        ..clear();
      final created = await householdRepository().create(name: 'Game night');

      await drain().drain();
      // A send that got no answer is handed back uncounted
      // (`SyncFailure.unreachable`), so the entry has no cooldown to wait out.
      harness.server.json(
        'POST',
        '/api/households',
        _createAnswer,
        status: 201,
      );
      await drain().drain();

      expect(
        creates().map((request) => (request.data! as Map)['clientRequestId']),
        [created.operation.localId, created.operation.localId],
      );
      expect(await queue().getOutstandingEntries(), isEmpty);
      expect(await householdIds(), ['hh-server']);
    });

    test('a restart with work still queued delivers it (#121, #142)', () async {
      await activated();
      await householdRepository().create(name: 'Game night');
      // Nothing wakes the drain on an enqueue, so the op is still queued.
      expect(creates(), isEmpty);
      await harness.shutdown();

      harness.server
        ..clear()
        ..json('POST', '/api/households', _createAnswer, status: 201);
      await harness.boot();
      await harness.restoreSession();
      await harness.activateUser();
      await harness.awaitHydrated();
      // The drain's first pass sends it, after activation returns and with
      // no status that reports it, so this waits on the queue itself. Not
      // `joinOrRunDrainPass`: with no pass in flight that runs one, and would
      // hide a root that never started its own.
      var outstanding = const <SyncQueueEntry>[];
      await pollUntil(
        () async =>
            (outstanding = await queue().getOutstandingEntries()).isEmpty,
        describe: () =>
            'The queue still holds '
            '${outstanding.map((e) => '${e.id} ${e.status.name}').toList()}',
      );

      expect(creates(), hasLength(1));
      expect(await queue().getOutstandingEntries(), isEmpty);
      expect(await householdIds(), ['hh-server']);
    });

    // The re-send once `SyncQueueEntry.claimLease` has run out is pinned at
    // the drain, in "a switch away between send and acknowledgement…" in
    // `packages/features/sync/test/sync_queue_drain_test.dart`. The native
    // root has no clock seam to move past the lease, and adding one needs a
    // decision. This is a plain background and resume: #174's race, a
    // timer-driven suspend that bypasses the operation lock, is not
    // exercised here.
    //
    // The test calls the context's `background()`, `suspend()` and
    // `activate()` itself, the calls `ServerOrchestratorImpl` makes. The
    // orchestrator has no call that backgrounds the active server: it
    // backgrounds one only when another server becomes active, and suspends
    // it only when its backgrounding timer fires, which is #174's path
    // (#435). Its active id and saved state stay as they were, as across a
    // resume. The switch-away demotion is pinned in
    // `packages/core/di/test/server_orchestrator_impl_test.dart`.
    test('a server backgrounded between send and acknowledgement keeps the '
        "op, and doesn't send it again inside the claim (#121)", () async {
      await activated();
      final release = Completer<ScriptedResponse>();
      addTearDown(() {
        if (!release.isCompleted) {
          release.complete(ScriptedResponse.json(const <String, Object?>{}));
        }
      });
      harness.server
        ..hold('POST', '/api/households', release.future)
        ..clear();
      final created = await householdRepository().create(name: 'Game night');

      unawaited(drain().drain());
      await harness.awaitRequests('POST', '/api/households');
      await harness.active.background();
      await harness.active.suspend();
      release.complete(ScriptedResponse.json(_createAnswer, status: 201));
      await pumpEventQueue();

      // The suspend disposed the server scope and its Dio, so the activation
      // builds a new one, which needs the transport swapped again.
      await harness.active.activate();
      harness.swapTransport();
      await harness.restoreSession();
      await harness.activateUser();
      await harness.awaitHydrated();
      // The pass the new user scope started, which finds the entry claimed.
      await harness.joinOrRunDrainPass();

      expect(creates(), hasLength(1));
      expect(
        await queue().getOutstandingEntries(),
        [
          isA<SyncQueueEntry>()
              .having((entry) => entry.id, 'id', created.syncQueueId)
              .having((entry) => entry.status, 'status', SyncStatus.inProgress)
              .having((entry) => entry.retryCount, 'retryCount', 0),
        ],
        reason: 'its claim holds it, not the cooldown a counted failure starts',
      );
      expect(await householdIds(), [created.operation.localId]);
      expect(
        harness.escapedRequests,
        isEmpty,
        reason: 'every request after the resume went through the new Dio',
      );
    });
  });
}
