import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';
import 'package:sync_queue/sync_queue.dart';

import 'support/counting_queue.dart';
import 'support/harness.dart';

class _MockLogger extends Mock implements BgeLogger {}

class _MockQueue extends Mock implements SyncQueueRepository {}

/// The drain over the real sender, the real repositories and fake remotes
/// (#121): what one pass sends, where it stops, and what it holds back.
void main() {
  late Harness h;
  late int revalidations;
  late SyncQueueDrain drain;

  SyncQueueDrain openDrain() => SyncQueueDrain(
    queue: h.queue,
    sender: h.sender,
    revalidateSession: () async => revalidations++,
    now: h.deviceNow,
  );

  setUp(() async {
    h = await Harness.open();
    revalidations = 0;
    drain = openDrain();
  });

  tearDown(() async {
    await drain.close();
    await h.close();
  });

  Future<SyncQueueEntry> entry(String id) => h.entry(id);

  group('one pass', () {
    test(
      'delivers every queued op, households and collections alike',
      () async {
        final create = await h.queuedCreate();
        final add = await h.queuedAdd();

        await drain.drain();

        expect((await entry(create.id)).status, SyncStatus.completed);
        expect((await entry(add.id)).status, SyncStatus.completed);
        expect(h.householdRemote.creates, hasLength(1));
        expect(h.collectionRemote.writes, hasLength(1));
      },
    );

    test('stops at a server error, counting it, and sends nothing '
        'after', () async {
      final first = await h.queuedCreate(name: 'First');
      final second = await h.queuedAdd();
      h.householdRemote.respond = (_) =>
          throw const HouseholdRemoteTransientException(
            'Household create failed',
            statusCode: 503,
          );

      await drain.drain();

      expect((await entry(first.id)).retryCount, 1);
      expect(h.collectionRemote.writes, isEmpty);
      expect((await entry(second.id)).status, SyncStatus.pending);
    });

    test('stops when nothing answers, handing the op back uncounted', () async {
      final first = await h.queuedCreate();
      await h.queuedAdd();
      h.householdRemote.respond = (_) =>
          throw const HouseholdRemoteTransientException('connection refused');

      await drain.drain();

      final failed = await entry(first.id);
      expect(failed.status, SyncStatus.pending);
      expect(failed.retryCount, 0);
      expect(h.collectionRemote.writes, isEmpty);
    });

    test('parks a refused op and goes on to the next', () async {
      final refused = await h.queuedCreate();
      final next = await h.queuedAdd();
      h.householdRemote.respond = (_) =>
          throw const HouseholdRemotePermanentException(
            'Household create returned 422',
            statusCode: 422,
          );

      await drain.drain();

      expect((await entry(refused.id)).isExhausted, isTrue);
      expect((await entry(next.id)).status, SyncStatus.completed);
    });

    test('goes on past an op that cannot be sent as it stands', () async {
      final malformed = await h.queue.enqueue(
        const RemoveFromCollectionOperation(collectionId: ''),
      );
      // The remote refuses the empty id before any request.
      h.collectionRemote.respond = (write) =>
          throw ArgumentError.value(write.id, 'id');
      final next = await h.queuedCreate();

      await drain.drain();

      expect((await entry(malformed.id)).retryCount, 1);
      expect((await entry(next.id)).status, SyncStatus.completed);
    });

    test('counts a payload that will not decode, and goes on', () async {
      final unreadable = await h.queue.enqueue(
        const CreateHouseholdOperation(localId: 'hh-local', name: 'HQ'),
      );
      await h.db.customStatement(
        'UPDATE sync_queue SET payload = ? WHERE id = ?',
        ['{not json', unreadable.id],
      );
      final next = await h.queuedCreate();

      await drain.drain();

      final counted = await entry(unreadable.id);
      expect(counted.status, SyncStatus.failed);
      expect(counted.retryCount, 1);
      expect((await entry(next.id)).status, SyncStatus.completed);
    });
  });

  group('counted retries are spaced out', () {
    void failCreates() {
      h.householdRemote.respond = (_) =>
          throw const HouseholdRemoteTransientException(
            'Household create failed',
            statusCode: 503,
          );
    }

    test('a counted op waits out its cooldown before it is sent '
        'again', () async {
      await h.queuedCreate();
      failCreates();
      await drain.drain();
      expect(h.householdRemote.creates, hasLength(1));

      h.advance(const Duration(seconds: 59));
      await drain.drain();
      expect(h.householdRemote.creates, hasLength(1), reason: 'still cooling');

      h.advance(const Duration(seconds: 1));
      await drain.drain();
      expect(h.householdRemote.creates, hasLength(2));
    });

    test('the cooldown grows with the retry count', () async {
      final queued = await h.queuedCreate();
      failCreates();
      for (final wait in [
        Duration.zero,
        const Duration(minutes: 1),
        const Duration(minutes: 10),
      ]) {
        h.advance(wait);
        await drain.drain();
      }
      expect((await entry(queued.id)).retryCount, 3);

      h.advance(const Duration(minutes: 59));
      await drain.drain();
      expect((await entry(queued.id)).retryCount, 3, reason: 'an hour now');

      h.advance(const Duration(minutes: 1));
      await drain.drain();
      expect((await entry(queued.id)).retryCount, 4);
    });

    test('an attempt handed back uncounted does not start the cooldown '
        'again', () async {
      final queued = await h.queuedCreate();
      failCreates();
      await drain.drain();
      h.advance(const Duration(minutes: 1));
      h.householdRemote.respond = (_) =>
          throw const HouseholdRemoteTransientException('connection refused');
      await drain.drain();
      expect(h.householdRemote.creates, hasLength(2));
      expect((await entry(queued.id)).retryCount, 1);

      // Back a second later. The minute was waited out before that attempt,
      // and one that never reached the server doesn't start it again.
      h.householdRemote.respond = (_) => serverHousehold();
      h.advance(const Duration(seconds: 1));
      await pumpEventQueue();
      expect(drain.isStale, isTrue);
      await drain.drain();
      expect((await entry(queued.id)).status, SyncStatus.completed);
    });

    test('an unreadable payload waits out its cooldown like any counted '
        'failure', () async {
      final unreadable = await h.queue.enqueue(
        const CreateHouseholdOperation(localId: 'hh-local', name: 'HQ'),
      );
      await h.db.customStatement(
        'UPDATE sync_queue SET payload = ? WHERE id = ?',
        ['{not json', unreadable.id],
      );

      await drain.drain();
      await drain.drain();
      expect((await entry(unreadable.id)).retryCount, 1);
      await pumpEventQueue();
      expect(drain.isStale, isFalse, reason: 'cooling, not sendable');

      h.advance(const Duration(minutes: 1));
      expect(drain.isStale, isTrue);
      await drain.drain();
      expect((await entry(unreadable.id)).retryCount, 2);
    });

    test('an op behind a cooling op of the same entry waits with '
        'it', () async {
      await h.confirmedEntry();
      await h.collection.updateCollectionEntry(id: 'gc-server', quantity: 2);
      await h.collection.updateCollectionEntry(id: 'gc-server', quantity: 3);
      h.collectionRemote.respond = (_) =>
          throw const GameCollectionRemoteTransientException(
            'Collection update failed',
            statusCode: 500,
          );
      await drain.drain();
      expect(h.collectionRemote.writes, hasLength(1));

      // The server is back, but the first update is still cooling: sending
      // the second alone would land the edits out of order.
      h.collectionRemote.respond = (write) =>
          serverEntry(quantity: write.fields['quantity']! as int);
      await drain.drain();
      expect(h.collectionRemote.writes, hasLength(1));

      h.advance(const Duration(minutes: 1));
      await drain.drain();
      expect(
        h.collectionRemote.writes.skip(1).map((w) => w.fields['quantity']),
        [2, 3],
      );
    });
  });

  group('isStale answers from the last pass', () {
    test('is true before the first pass', () {
      expect(drain.isStale, isTrue);
    });

    test('is false after a pass that left nothing to send', () async {
      await h.queuedCreate();
      await drain.drain();
      await pumpEventQueue();

      expect(drain.isStale, isFalse);
    });

    test('is false while every op is cooling, and true once one is '
        'ready', () async {
      await h.queuedCreate();
      h.householdRemote.respond = (_) =>
          throw const HouseholdRemoteTransientException(
            'Household create failed',
            statusCode: 503,
          );
      await drain.drain();
      await pumpEventQueue();
      expect(drain.isStale, isFalse);

      h.advance(const Duration(minutes: 1));
      expect(drain.isStale, isTrue);
    });

    test('turns true when an op is queued', () async {
      await drain.drain();
      await pumpEventQueue();
      expect(drain.isStale, isFalse);

      await h.queuedCreate();
      await pumpEventQueue();

      expect(drain.isStale, isTrue);
    });

    test('stays true after a pass that handed an op back', () async {
      await h.queuedCreate();
      h.householdRemote.respond = (_) =>
          throw const HouseholdRemoteTransientException('connection refused');
      await drain.drain();
      await pumpEventQueue();

      expect(drain.isStale, isTrue);
    });

    test('is false for an op only a parked add holds back', () async {
      final add = await h.queuedAdd();
      await h.collection.updateCollectionEntry(id: add.local.id, quantity: 2);
      h.collectionRemote.respond = (_) =>
          throw const GameCollectionNotFoundException(
            'Collection add returned 404',
            statusCode: 404,
          );
      await drain.drain();
      await pumpEventQueue();

      expect(drain.isStale, isFalse);
    });

    test("turns true when another sender's claim runs out", () async {
      // The inline create is mid-send when the drain settles: the op is
      // claimed, so no pass lists it, and its send can fail without
      // changing the pending count.
      final queued = await h.queuedCreate();
      expect(await h.queue.claim(queued.id), isTrue);
      await drain.drain();
      await pumpEventQueue();
      expect(drain.isStale, isFalse);

      h.advance(SyncQueueEntry.claimLease);

      expect(drain.isStale, isTrue);
    });

    test('waits out a claim stamped ahead of a clock set back, as a claim '
        'does', () async {
      // A sender died holding the claim, and the clock was then set back an
      // hour: no sender can take it until the clock passes its lease.
      final queued = await h.queuedCreate();
      expect(await h.queue.claim(queued.id), isTrue);
      h.advance(const Duration(hours: -1));
      await drain.drain();
      await pumpEventQueue();
      expect(drain.isStale, isFalse);
      expect(h.householdRemote.creates, isEmpty);

      h.advance(
        const Duration(hours: 1) +
            SyncQueueEntry.claimLease +
            const Duration(seconds: 1),
      );
      expect(drain.isStale, isTrue);
      await drain.drain();
      expect((await entry(queued.id)).status, SyncStatus.completed);
    });

    test('is false while a pass runs, and after close', () async {
      await h.queuedCreate();
      final pass = drain.drain();
      expect(drain.isStale, isFalse);
      await pass;

      await h.queuedCreate();
      await drain.close();
      expect(drain.isStale, isFalse);
    });
  });

  test('a pass reads the queue once to send, and once more to settle, '
      'however many ops it sends', () async {
    // Two updates to one entry, an add nothing waits on, and a household
    // create: a read per update, or a fresh listing after each add, would
    // cost the pass a read of every row per op.
    await h.confirmedEntry();
    await h.collection.updateCollectionEntry(id: 'gc-server', quantity: 2);
    await h.collection.updateCollectionEntry(id: 'gc-server', quantity: 3);
    await h.collection.addToCollection(
      platformGameId: kPlatformGameId,
      medium: GameMedium.digital,
      quantity: 1,
    );
    final create = await h.queuedCreate();
    h.collectionRemote.respond = (write) => write.method == 'POST'
        ? GameCollection(
            id: 'gc-digital',
            userId: kUserId,
            platformGameId: kPlatformGameId,
            medium: GameMedium.digital,
            quantity: 1,
            createdAt: DateTime.utc(2026, 10),
            updatedAt: DateTime.utc(2026, 10, 2),
          )
        : serverEntry(quantity: write.fields['quantity']! as int);
    final counted = CountingQueue(h.queue);
    await drain.close();
    drain = SyncQueueDrain(queue: counted, sender: h.sender, now: h.deviceNow);

    await drain.drain();

    expect(h.collectionRemote.writes.map((w) => w.method), [
      'PATCH',
      'PATCH',
      'POST',
    ]);
    expect((await entry(create.id)).status, SyncStatus.completed);
    expect(counted.reads, 2);
  });

  group("one entry's ops stay in order", () {
    test('a parked op holds its entry back for the rest of the pass, '
        'not after', () async {
      await h.confirmedEntry();
      await h.collection.updateCollectionEntry(id: 'gc-server', quantity: 2);
      await h.collection.updateCollectionEntry(id: 'gc-server', quantity: 3);
      var refused = false;
      h.collectionRemote.respond = (write) {
        if (!refused) {
          refused = true;
          throw const GameCollectionNotFoundException(
            'Collection update returned 404',
            statusCode: 404,
          );
        }
        return serverEntry(quantity: write.fields['quantity']! as int);
      };

      await drain.drain();
      expect(h.collectionRemote.writes, hasLength(1));

      // A parked edit doesn't hold a newer one it doesn't depend on.
      await drain.drain();
      expect(h.collectionRemote.writes.last.fields['quantity'], 3);
    });

    test('an update behind an unacknowledged add is held, a parked add '
        'included', () async {
      final add = await h.queuedAdd();
      await h.collection.updateCollectionEntry(id: add.local.id, quantity: 2);
      h.collectionRemote.respond = (_) =>
          throw const GameCollectionNotFoundException(
            'Collection add returned 404',
            statusCode: 404,
          );

      await drain.drain();
      await drain.drain();

      expect(h.collectionRemote.writes.map((w) => w.method), ['POST']);
    });

    test('an update behind an add another sender holds is held', () async {
      final add = await h.queuedAdd();
      await h.collection.updateCollectionEntry(id: add.local.id, quantity: 2);
      expect(await h.queue.claim(add.id), isTrue);

      await drain.drain();

      expect(h.collectionRemote.writes, isEmpty);
    });

    test('a removal behind an add goes out under the server id once the '
        'add lands', () async {
      final add = await h.queuedAdd();
      await h.collection.removeFromCollection(add.local.id);
      h.collectionRemote.respond = (write) => write.method == 'DELETE'
          ? serverEntry(deletedAt: DateTime.utc(2026, 10, 3))
          : serverEntry();

      await drain.drain();

      expect(h.collectionRemote.writes.map((w) => (w.method, w.id)), [
        ('POST', null),
        ('DELETE', 'gc-server'),
      ]);
      expect(await h.collection.getCollection(), isEmpty);
    });
  });

  test('an op rewritten after the listing waits for a pass that reads '
      'it again', () async {
    await h.confirmedEntry();
    final create = await h.queuedCreate();
    await h.collection.updateCollectionEntry(id: 'gc-server', quantity: 2);
    // While the create is out, something else (a hydrate's merge, say)
    // remaps the entry's ops: the update this pass listed is stale.
    h.householdRemote.respond = (_) async {
      await h.queue.remapCollectionId(
        oldCollectionId: 'gc-server',
        newCollectionId: 'gc-moved',
      );
      return serverHousehold();
    };
    h.collectionRemote.respond = (_) => serverEntry(id: 'gc-moved');

    await drain.drain();
    expect((await entry(create.id)).status, SyncStatus.completed);
    expect(h.collectionRemote.writes, isEmpty);

    await drain.drain();
    expect(h.collectionRemote.writes.single.id, 'gc-moved');
  });

  group('the session ending', () {
    test('close stops the pass at the next op', () async {
      await h.queuedCreate(name: 'First');
      await h.queuedCreate(name: 'Second');
      h.householdRemote.respond = (create) async {
        await drain.close();
        return serverHousehold(id: 'hh-${create.name}');
      };

      await drain.drain();

      expect(h.householdRemote.creates.map((c) => c.name), ['First']);
    });

    test('a teardown mid-pass ends it quietly', () async {
      final logger = _MockLogger();
      await drain.close();
      drain = SyncQueueDrain(
        queue: h.queue,
        sender: h.sender,
        now: h.deviceNow,
        logger: logger,
      );
      await h.queuedCreate(name: 'First');
      await h.queuedCreate(name: 'Second');
      h.householdRemote.respond = (_) async {
        // The scope pop, in get_it's order: the drain was registered after
        // the repositories, so it is closed before they are disposed.
        await drain.close();
        await h.households.onDispose();
        await h.queue.onDispose();
        return serverHousehold();
      };

      await expectLater(drain.drain(), completes);
      expect(h.householdRemote.creates, hasLength(1));
      verifyNever(
        () => logger.error(
          any(),
          error: any(named: 'error'),
          stackTrace: any(named: 'stackTrace'),
          context: any(named: 'context'),
        ),
      );
    });

    test('a fault while the drain is open is logged, a StateError '
        'included', () async {
      // Say a row the queue can't read: nothing is ending, so it is a fault
      // to report, not a teardown to pass over.
      final logger = _MockLogger();
      final queue = _MockQueue();
      when(queue.watchPendingCount).thenAnswer((_) => Stream.value(1));
      when(queue.getPendingCount).thenAnswer((_) async => 1);
      when(queue.getOutstandingEntries).thenThrow(StateError('unreadable row'));
      final open = SyncQueueDrain(
        queue: queue,
        sender: h.sender,
        now: h.deviceNow,
        logger: logger,
      );
      addTearDown(open.close);

      await open.drain();

      verify(
        () => logger.error(
          'Sync queue pass failed',
          error: any(named: 'error', that: isA<StateError>()),
          stackTrace: any(named: 'stackTrace'),
        ),
      ).called(1);
    });

    test('a switch away between send and acknowledgement re-sends after '
        'the claim, and the key makes it a replay (#435)', () async {
      final queued = await h.queuedCreate();
      // The server creates it, but the session ends before the answer is
      // recorded: the acknowledgement meets disposed repositories, and the
      // entry is left claimed.
      h.householdRemote.respond = (_) async {
        await h.newSession();
        return serverHousehold();
      };
      await drain.drain();
      await drain.close();

      // Back on this server: a new session, a new drain.
      h.householdRemote.respond = (_) => serverHousehold();
      drain = openDrain();
      await drain.drain();
      expect(
        h.householdRemote.creates,
        hasLength(1),
        reason: 'the first claim still holds the entry',
      );

      // Past the lease: the queue frees a claim only once it is older.
      h.advance(SyncQueueEntry.claimLease + const Duration(seconds: 1));
      await drain.drain();

      expect(h.householdRemote.creates.map((c) => c.clientRequestId), [
        queued.op.localId,
        queued.op.localId,
      ]);
      expect((await entry(queued.id)).status, SyncStatus.completed);
      final households = await h.households.watchHouseholds().first;
      expect(households.map((x) => x.id), ['hh-server']);
    });

    test('a restart with work still queued delivers it', () async {
      final queued = await h.queuedCreate();
      await drain.close();
      await h.newSession();
      drain = openDrain();

      await drain.drain();

      expect((await entry(queued.id)).status, SyncStatus.completed);
    });
  });

  test('a replayed create the server has since deleted disappears '
      'locally (#438)', () async {
    // The first send landed but its answer was lost, and the household was
    // deleted on another device before this retry. The key's replay returns
    // it with deletedAt set, onto the local-only optimistic row.
    final queued = await h.queuedCreate();
    h.householdRemote.respond = (_) =>
        serverHousehold(deletedAt: DateTime.utc(2026, 10, 2));

    await drain.drain();

    expect((await entry(queued.id)).status, SyncStatus.completed);
    expect(await h.households.watchHouseholds().first, isEmpty);
    expect(
      h.households.reconciledHouseholdId(queued.household.id),
      'hh-server',
    );
  });

  group('a refused session (401)', () {
    test('hands the op back, stops, and asks the auth layer once', () async {
      final first = await h.queuedCreate(name: 'First');
      await h.queuedCreate(name: 'Second');
      h.householdRemote.respond = (_) =>
          throw const HouseholdRemoteTransientException(
            'Household create failed',
            statusCode: 401,
          );

      await drain.drain();

      expect(revalidations, 1);
      expect(h.householdRemote.creates, hasLength(1));
      final released = await entry(first.id);
      expect(released.status, SyncStatus.pending);
      expect(released.retryCount, 0);
    });

    test('a revalidation that throws stays inside the pass', () async {
      await h.queuedCreate();
      h.householdRemote.respond = (_) =>
          throw const HouseholdRemoteTransientException(
            'Household create failed',
            statusCode: 401,
          );
      await drain.close();
      drain = SyncQueueDrain(
        queue: h.queue,
        sender: h.sender,
        revalidateSession: () async => throw StateError('auth is down'),
        now: h.deviceNow,
      );

      await expectLater(drain.drain(), completes);
    });
  });
}
