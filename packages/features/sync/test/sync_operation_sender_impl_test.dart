import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/sync.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import 'support/harness.dart';

/// The one delivery path both the inline create and the drain take (#121).
///
/// Runs the real repositories over one in-memory database, so what a test
/// reads back is what the queue and the cache actually hold, and fakes only
/// the network.
void main() {
  late Harness h;

  setUp(() async => h = await Harness.open());
  tearDown(() => h.close());

  group('a household create', () {
    test('is sent keyed by its localId, reconciled, and completed', () async {
      final queued = await h.queuedCreate(name: 'Game Night');

      final delivery = await h.sender.deliver(queued.id, queued.op);

      expect(delivery, isA<SyncDelivered>());
      expect((delivery as SyncDelivered).householdId, 'hh-server');
      expect(
        h.householdRemote.creates.single.clientRequestId,
        queued.op.localId,
      );
      expect(h.householdRemote.creates.single.name, 'Game Night');
      expect((await h.entry(queued.id)).status, SyncStatus.completed);
      final household = (await h.households.watchHouseholds().first).single;
      expect(household.id, 'hh-server');
      expect(household.isLocalOnly, isFalse);
    });

    test('is not sent when another sender holds it', () async {
      final queued = await h.queuedCreate();
      expect(await h.queue.claim(queued.id), isTrue);

      final delivery = await h.sender.deliver(queued.id, queued.op);

      expect(delivery, isA<SyncNotClaimed>());
      expect(h.householdRemote.creates, isEmpty);
    });

    test('refused as it stands, is parked, not cancelled', () async {
      final queued = await h.queuedCreate();
      h.householdRemote.respond = (_) =>
          throw const HouseholdRemotePermanentException(
            'Household create returned 400',
            statusCode: 400,
          );

      final delivery = await h.sender.deliver(queued.id, queued.op);

      expect(delivery, isA<SyncParked>());
      final entry = await h.entry(queued.id);
      expect(entry.status, SyncStatus.failed);
      expect(entry.isExhausted, isTrue);
      expect(entry.lastError, contains('400'));
      final household = (await h.households.watchHouseholds().first).single;
      expect(
        household.id,
        queued.household.id,
        reason: 'kept, not rolled back',
      );
      expect(household.isLocalOnly, isTrue);
    });

    test('a 2xx whose body would not parse is counted, never parked: the '
        'server made the household, and the retry settles it', () async {
      final queued = await h.queuedCreate();
      h.householdRemote.respond = (_) =>
          throw const HouseholdRemotePermanentException(
            'Household create response missing a "household" object',
            statusCode: 201,
          );

      final unread = await h.sender.deliver(queued.id, queued.op);

      expect(
        unread,
        isA<SyncFailed>().having(
          (d) => d.failure,
          'failure',
          SyncFailure.localFault,
        ),
      );
      final entry = await h.entry(queued.id);
      expect(entry.retryCount, 1);
      expect(entry.isExhausted, isFalse);

      // The retry carries the same key (#131), so the server answers with
      // the household the first attempt made, and the optimistic row moves
      // onto it instead of sitting beside the hydrate's copy.
      h.householdRemote.respond = (_) => serverHousehold();
      final retried = await h.sender.deliver(queued.id, queued.op);

      expect(retried, isA<SyncDelivered>());
      expect(h.householdRemote.creates.map((c) => c.clientRequestId).toSet(), {
        queued.op.localId,
      });
      final households = await h.households.watchHouseholds().first;
      expect(households.single.id, 'hh-server');
    });

    group('a transient failure', () {
      Future<(SyncDelivery, SyncQueueEntry)> failWith(int? status) async {
        final queued = await h.queuedCreate();
        h.householdRemote.respond = (_) =>
            throw HouseholdRemoteTransientException(
              'Household create failed',
              statusCode: status,
            );
        final delivery = await h.sender.deliver(queued.id, queued.op);
        return (delivery, await h.entry(queued.id));
      }

      for (final status in [500, 502, 503, 409]) {
        test('$status is counted: the application processed it', () async {
          final (delivery, entry) = await failWith(status);

          expect(
            delivery,
            isA<SyncFailed>().having(
              (d) => d.failure,
              'failure',
              SyncFailure.serverError,
            ),
          );
          expect(entry.status, SyncStatus.failed);
          expect(entry.retryCount, 1);
        });
      }

      for (final status in [null, 403, 404, 407, 408, 429, 302]) {
        test('$status is handed back uncounted: it never reached the '
            'application', () async {
          final (delivery, entry) = await failWith(status);

          expect(
            delivery,
            isA<SyncFailed>().having(
              (d) => d.failure,
              'failure',
              SyncFailure.unreachable,
            ),
          );
          expect(entry.status, SyncStatus.pending);
          expect(entry.retryCount, 0);
        });
      }

      test('401 is handed back uncounted as a refused session', () async {
        final (delivery, entry) = await failWith(401);

        expect(
          delivery,
          isA<SyncFailed>().having(
            (d) => d.failure,
            'failure',
            SyncFailure.sessionRejected,
          ),
        );
        expect(entry.status, SyncStatus.pending);
        expect(entry.retryCount, 0);
      });

      test('a 2xx this device could not decode is counted', () async {
        final (delivery, entry) = await failWith(201);

        expect(
          delivery,
          isA<SyncFailed>().having(
            (d) => d.failure,
            'failure',
            SyncFailure.localFault,
          ),
        );
        expect(entry.retryCount, 1);
      });
    });

    test('a request the server would refuse is a counted client fault, '
        'never parked', () async {
      final queued = await h.queuedCreate();
      h.householdRemote.respond = (_) =>
          throw ArgumentError.value('', 'clientRequestId');

      final delivery = await h.sender.deliver(queued.id, queued.op);

      expect(
        delivery,
        isA<SyncFailed>().having(
          (d) => d.failure,
          'failure',
          SyncFailure.invalidOp,
        ),
      );
      final entry = await h.entry(queued.id);
      expect(entry.retryCount, 1);
      expect(entry.isExhausted, isFalse);
    });

    test('a reconcile that fails after the server created it is counted, '
        'not handed back', () async {
      final queued = await h.queuedCreate();
      // The household repository goes with its session; the queue is still
      // open, so the failure can be recorded.
      await h.households.onDispose();

      final delivery = await h.sender.deliver(queued.id, queued.op);

      expect(
        delivery,
        isA<SyncFailed>().having(
          (d) => d.failure,
          'failure',
          SyncFailure.localFault,
        ),
      );
      final entry = await h.entry(queued.id);
      expect(entry.status, SyncStatus.failed);
      expect(entry.retryCount, 1);
    });

    test('a queue write that fails is logged, and the outcome still '
        'returned', () async {
      final queued = await h.queuedCreate();
      h.householdRemote.respond = (_) async {
        // The session ends mid-send: every write after this throws.
        await h.queue.onDispose();
        throw const HouseholdRemoteTransientException(
          'Household create failed',
          statusCode: 503,
        );
      };

      final delivery = await h.sender.deliver(queued.id, queued.op);

      expect(delivery, isA<SyncFailed>());
    });

    test('a claim that throws is the one failure deliver lets out', () async {
      final queued = await h.queuedCreate();
      await h.queue.onDispose();

      await expectLater(
        h.sender.deliver(queued.id, queued.op),
        throwsStateError,
      );
      expect(h.householdRemote.creates, isEmpty);
    });
  });

  group('deliverEntry', () {
    Future<void> corrupt(String entryId) => h.db.customStatement(
      'UPDATE sync_queue SET payload = ? WHERE id = ?',
      ['{not json', entryId],
    );

    test('sends the op the entry holds', () async {
      final queued = await h.queuedCreate();

      final delivery = await h.sender.deliverEntry(await h.entry(queued.id));

      expect(delivery, isA<SyncDelivered>());
      expect(
        h.householdRemote.creates.single.clientRequestId,
        queued.op.localId,
      );
    });

    test('leaves an op rewritten since it was read for a sender that reads '
        'it again', () async {
      await h.confirmedEntry(serverId: 'gc-old');
      await h.collection.updateCollectionEntry(id: 'gc-old', quantity: 4);
      final read = (await h.queue.getPendingEntries()).single;
      await h.queue.remapCollectionId(
        oldCollectionId: 'gc-old',
        newCollectionId: 'gc-server',
      );
      h.collectionRemote.respond = (_) => serverEntry(quantity: 4);

      final stale = await h.sender.deliverEntry(read);

      expect(stale, isA<SyncNotClaimed>());
      expect(h.collectionRemote.writes, isEmpty);

      final reread = (await h.queue.getPendingEntries()).single;
      expect(await h.sender.deliverEntry(reread), isA<SyncDelivered>());
      expect(h.collectionRemote.writes.single.id, 'gc-server');
    });

    test('counts a payload that will not decode, and sends nothing', () async {
      final queued = await h.queuedCreate();
      await corrupt(queued.id);

      final delivery = await h.sender.deliverEntry(await h.entry(queued.id));

      expect(
        delivery,
        isA<SyncFailed>().having(
          (d) => d.failure,
          'failure',
          SyncFailure.invalidOp,
        ),
      );
      expect(h.householdRemote.creates, isEmpty);
      final entry = await h.entry(queued.id);
      expect(entry.retryCount, 1);
      expect(entry.isExhausted, isFalse, reason: 'counted, never parked');
    });

    test('leaves an unreadable entry alone while another sender holds '
        'it', () async {
      final queued = await h.queuedCreate();
      await corrupt(queued.id);
      expect(await h.queue.claim(queued.id), isTrue);

      final delivery = await h.sender.deliverEntry(await h.entry(queued.id));

      expect(delivery, isA<SyncNotClaimed>());
      expect((await h.entry(queued.id)).retryCount, 0);
    });
  });

  group('a collection write', () {
    Future<SyncQueueEntry> onlyPending() async =>
        (await h.queue.getPendingEntries()).single;

    test('an add is sent and reconciled onto the server id', () async {
      final queued = await h.queuedAdd(quantity: 2);
      h.collectionRemote.respond = (_) => serverEntry(quantity: 2);

      final delivery = await h.sender.deliver(queued.id, queued.op);

      expect(delivery, isA<SyncDelivered>());
      final write = h.collectionRemote.writes.single;
      expect(write.method, 'POST');
      expect(write.fields['platformGameId'], kPlatformGameId);
      expect(write.fields['medium'], GameMedium.physical);
      expect(write.fields['quantity'], 2);
      final added = await h.onlyEntry();
      expect(added.id, 'gc-server');
      expect(added.isDirty, isFalse);
      expect(added.isLocalOnly, isFalse);
      expect((await h.entry(queued.id)).status, SyncStatus.completed);
    });

    test('an add whose 2xx body would not parse is counted, never '
        'parked', () async {
      final queued = await h.queuedAdd();
      h.collectionRemote.respond = (_) =>
          throw const GameCollectionRemotePermanentException(
            'Collection add returned a body that is not JSON',
            statusCode: 201,
          );

      final delivery = await h.sender.deliver(queued.id, queued.op);

      expect(
        delivery,
        isA<SyncFailed>().having(
          (d) => d.failure,
          'failure',
          SyncFailure.localFault,
        ),
      );
      final entry = await h.entry(queued.id);
      expect(entry.retryCount, 1);
      expect(entry.isExhausted, isFalse);
    });

    test('an update is sent to the entry it names', () async {
      await h.confirmedEntry();
      await h.collection.updateCollectionEntry(id: 'gc-server', quantity: 4);
      final update = await onlyPending();
      h.collectionRemote.respond = (_) => serverEntry(quantity: 4);

      final delivery = await h.sender.deliver(update.id, update.operation);

      expect(delivery, isA<SyncDelivered>());
      final write = h.collectionRemote.writes.single;
      expect(write.method, 'PATCH');
      expect(write.id, 'gc-server');
      expect(write.fields['quantity'], 4);
      final updated = await h.onlyEntry();
      expect(updated.quantity, 4);
      expect(updated.isDirty, isFalse);
    });

    test('an update the server answers with a tombstone purges the '
        'entry', () async {
      // Removed on another device: the backend answers a PATCH on a
      // tombstoned entry with 200 and `deletedAt` set.
      await h.confirmedEntry();
      await h.collection.updateCollectionEntry(id: 'gc-server', quantity: 4);
      final update = await onlyPending();
      h.collectionRemote.respond = (_) =>
          serverEntry(quantity: 4, deletedAt: DateTime.utc(2026, 10, 3));

      final delivery = await h.sender.deliver(update.id, update.operation);

      expect(delivery, isA<SyncDelivered>());
      expect(await h.collection.getCollection(), isEmpty);
      expect(await h.hydrateCanWriteFixtureGame(), isTrue);
      expect((await h.entry(update.id)).status, SyncStatus.completed);
    });

    test('a removal is sent, and the tombstone purged', () async {
      await h.confirmedEntry();
      await h.collection.removeFromCollection('gc-server');
      final remove = await onlyPending();
      h.collectionRemote.respond = (_) =>
          serverEntry(deletedAt: DateTime.utc(2026, 10, 3));

      final delivery = await h.sender.deliver(remove.id, remove.operation);

      expect(delivery, isA<SyncDelivered>());
      expect(h.collectionRemote.writes.single.method, 'DELETE');
      expect(await h.hydrateCanWriteFixtureGame(), isTrue);
      expect((await h.entry(remove.id)).status, SyncStatus.completed);
    });

    test('a removal the server already applied is settled as a '
        'delivery', () async {
      await h.confirmedEntry();
      await h.collection.removeFromCollection('gc-server');
      final remove = await onlyPending();
      h.collectionRemote.respond = (_) =>
          throw const GameCollectionAlreadyRemovedException(
            'Collection remove returned 404',
            statusCode: 404,
          );

      final delivery = await h.sender.deliver(remove.id, remove.operation);

      expect(delivery, isA<SyncDelivered>());
      expect(
        await h.hydrateCanWriteFixtureGame(),
        isTrue,
        reason: 'no dirty tombstone left for a merge to skip',
      );
      expect((await h.entry(remove.id)).status, SyncStatus.completed);
    });

    test('an entry the server does not have is parked', () async {
      await h.confirmedEntry();
      await h.collection.updateCollectionEntry(id: 'gc-server', quantity: 4);
      final update = await onlyPending();
      h.collectionRemote.respond = (_) =>
          throw const GameCollectionNotFoundException(
            'Collection update returned 404',
            statusCode: 404,
          );

      final delivery = await h.sender.deliver(update.id, update.operation);

      expect(delivery, isA<SyncParked>());
      expect((await h.entry(update.id)).isExhausted, isTrue);
      expect((await h.onlyEntry()).isDirty, isTrue);
    });

    test('a proxy 404 on a collection write is handed back', () async {
      await h.confirmedEntry();
      await h.collection.removeFromCollection('gc-server');
      final remove = await onlyPending();
      h.collectionRemote.respond = (_) =>
          throw const GameCollectionRemoteTransientException(
            'Collection remove returned 404 — the route was not reachable',
            statusCode: 404,
          );

      final delivery = await h.sender.deliver(remove.id, remove.operation);

      expect(
        delivery,
        isA<SyncFailed>().having(
          (d) => d.failure,
          'failure',
          SyncFailure.unreachable,
        ),
      );
      final entry = await h.entry(remove.id);
      expect(entry.status, SyncStatus.pending);
      expect(entry.retryCount, 0);
    });

    test('an id the remote will not put in a path is a counted client '
        'fault', () async {
      final entry = await h.queue.enqueue(
        const RemoveFromCollectionOperation(collectionId: 'gc/server'),
      );
      // What the real remote throws, before any request, for an id that
      // could reach another route.
      h.collectionRemote.respond = (write) =>
          throw ArgumentError.value(write.id, 'id');

      final delivery = await h.sender.deliver(entry.id, entry.operation);

      expect(
        delivery,
        isA<SyncFailed>().having(
          (d) => d.failure,
          'failure',
          SyncFailure.invalidOp,
        ),
      );
      final counted = await h.entry(entry.id);
      expect(counted.retryCount, 1);
      expect(counted.isExhausted, isFalse, reason: 'never parked');
    });

    test(
      'a medium this build does not know is a counted client fault',
      () async {
        final entry = await h.queue.enqueue(
          const AddToCollectionOperation(
            localId: 'gc-local',
            platformGameId: kPlatformGameId,
            medium: 'Holographic',
            quantity: 1,
          ),
        );

        final delivery = await h.sender.deliver(entry.id, entry.operation);

        expect(
          delivery,
          isA<SyncFailed>().having(
            (d) => d.failure,
            'failure',
            SyncFailure.invalidOp,
          ),
        );
        expect(h.collectionRemote.writes, isEmpty);
      },
    );
  });
}
