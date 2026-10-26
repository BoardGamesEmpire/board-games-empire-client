import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:sync_queue/sync_queue.dart';

import 'support/harness.dart';

class _MockQueue extends Mock implements SyncQueueRepository {}

class _MockCollection extends Mock implements GameCollectionRepository {}

class _MockHouseholds extends Mock implements HouseholdRepository {}

class _MockEvents extends Mock implements EventRepository {}

/// Retrying and discarding stuck ops (#190), over the real repositories and
/// sender with fake remotes.
void main() {
  late Harness h;
  late int collectionRefreshes;
  late int householdRefreshes;
  late int eventRefreshes;

  SyncRecovery recovery({SyncQueueDrain? drain}) => SyncRecovery(
    queue: h.queue,
    collection: h.collection,
    households: h.households,
    events: h.events,
    sender: h.sender,
    drain: drain?.drainAfterChange,
    refreshCollection: () async => collectionRefreshes++,
    refreshHouseholds: () async => householdRefreshes++,
    refreshEvents: () async => eventRefreshes++,
  );

  setUp(() async {
    h = await Harness.open();
    collectionRefreshes = 0;
    householdRefreshes = 0;
    eventRefreshes = 0;
  });

  tearDown(() async => h.close());

  void refuseEverything() {
    h.householdRemote.respond = (_) =>
        throw const HouseholdRemotePermanentException('rejected: 400');
    h.collectionRemote.respond = (_) =>
        throw const GameCollectionRemotePermanentException('rejected: 400');
    h.eventRemote.respond = (_) =>
        throw const EventCreateRefusedException('rejected: 403');
  }

  void acceptEverything() {
    h.householdRemote.respond = (_) => serverHousehold();
    h.collectionRemote.respond = (_) => serverEntry();
    h.eventRemote.respond = (_) => (snapshot: serverEvent(), deletedAt: null);
  }

  /// Sends [id] once while every send is refused, which parks it.
  Future<void> park(String id) async {
    refuseEverything();
    await h.sender.deliverEntry(await h.entry(id));
    expect((await h.entry(id)).isExhausted, isTrue);
  }

  /// A stuck entry whose payload no build can read.
  Future<String> garbledStuckEntry() async {
    final entry = await h.queue.enqueue(
      const CreateHouseholdOperation(localId: 'hh-local', name: 'HQ'),
    );
    await h.queue.park(entry.id, error: 'rejected: 400');
    await h.db.customStatement(
      'UPDATE sync_queue SET payload = ? WHERE id = ?',
      ['{not json', entry.id],
    );
    return entry.id;
  }

  group('watch', () {
    test('lists stuck ops in queue order, each with what it names', () async {
      final create = await h.queuedCreate(name: 'Smiths');
      final add = await h.queuedAdd();
      await h.queuedCreate(name: 'Still sending');
      await park(create.id);
      await park(add.id);

      final stuck = await recovery().watch().first;

      expect(stuck, [
        StuckSyncOp(
          entryId: create.id,
          kind: StuckSyncOpKind.createHousehold,
          subject: 'Smiths',
        ),
        StuckSyncOp(
          entryId: add.id,
          kind: StuckSyncOpKind.addToCollection,
          subject: 'Brass',
        ),
      ]);
    });

    test('names an update and a removal by their game', () async {
      await h.confirmedEntry();
      await h.collection.updateCollectionEntry(id: 'gc-server', quantity: 2);
      final update = (await h.queue.getOutstandingEntries()).single;
      await park(update.id);
      await h.collection.removeFromCollection('gc-server');
      final remove = (await h.queue.getOutstandingEntries()).last;
      await park(remove.id);

      final stuck = await recovery().watch().first;

      expect(stuck.map((s) => (s.kind, s.subject)), [
        (StuckSyncOpKind.updateCollection, 'Brass'),
        (StuckSyncOpKind.removeFromCollection, 'Brass'),
      ]);
    });

    test('a stuck event create is listed by its title', () async {
      final created = await h.events.create(eventDraft());
      await park(created.syncQueueId);

      final stuck = await recovery().watch().first;

      expect(stuck, [
        StuckSyncOp(
          entryId: created.syncQueueId,
          kind: StuckSyncOpKind.createEvent,
          subject: 'Game night',
        ),
      ]);
    });

    test('describes the stuck set again only when it changes', () async {
      final queue = _MockQueue();
      final collection = _MockCollection();
      final emissions = StreamController<List<SyncQueueEntry>>();
      addTearDown(emissions.close);
      when(queue.watchStuckEntries).thenAnswer((_) => emissions.stream);
      when(() => collection.titleOf(any())).thenAnswer((_) async => 'Brass');
      final stuck = SyncQueueEntry(
        id: 'q1',
        payload: const RemoveFromCollectionOperation(collectionId: 'gc-1')
            .serialized,
        status: SyncStatus.failed,
        retryCount: SyncQueueEntry.maxRetries,
        createdAt: DateTime.utc(2026, 10),
      );
      final described = <List<StuckSyncOp>>[];
      final subscription = SyncRecovery(
        queue: queue,
        collection: collection,
        households: _MockHouseholds(),
        events: _MockEvents(),
      ).watch().listen(described.add);
      addTearDown(subscription.cancel);

      // The queue re-reads on every write to it, a drain's claims included,
      // and emits the same stuck set each time.
      emissions
        ..add([stuck])
        ..add([stuck])
        ..add([stuck]);
      await pumpEventQueue();

      expect(described, hasLength(1));
      verify(() => collection.titleOf('gc-1')).called(1);
    });

    test('lists a payload that will not decode as unreadable', () async {
      final garbled = await garbledStuckEntry();

      final stuck = await recovery().watch().first;

      expect(stuck, [
        StuckSyncOp(entryId: garbled, kind: StuckSyncOpKind.unreadable),
      ]);
    });
  });

  group('retry', () {
    test('sends the op through the drain where there is one', () async {
      final create = await h.queuedCreate(name: 'Smiths');
      await park(create.id);
      acceptEverything();
      final drain = SyncQueueDrain(
        queue: h.queue,
        sender: h.sender,
        collection: h.collection,
        now: h.deviceNow,
      );
      addTearDown(drain.close);

      await recovery(drain: drain).retry(create.id);

      expect((await h.entry(create.id)).status, SyncStatus.completed);
      expect(await recovery().watch().first, isEmpty);
    });

    test('where nothing drains the queue, sends a household create '
        'inline', () async {
      final create = await h.queuedCreate(name: 'Smiths');
      await park(create.id);
      acceptEverything();

      expect(await recovery().retry(create.id), isTrue);

      expect((await h.entry(create.id)).status, SyncStatus.completed);
    });

    test('sends a stuck event create inline where no drain runs', () async {
      final created = await h.events.create(eventDraft());
      await park(created.syncQueueId);
      acceptEverything();

      expect(await recovery().retry(created.syncQueueId), isTrue);

      expect((await h.entry(created.syncQueueId)).status, SyncStatus.completed);
      expect(
        h.eventRemote.creates,
        hasLength(2),
        reason: 'the park, then this',
      );
      final events = await h.events.watchAttendingEvents().first;
      expect(events.map((e) => e.id), ['ev-server']);
    });

    test('where nothing drains the queue, reopens a collection op but '
        'leaves it for a drain, which keeps its entry in order', () async {
      final add = await h.queuedAdd();
      await park(add.id);
      acceptEverything();

      expect(await recovery().retry(add.id), isTrue);

      final reopened = await h.entry(add.id);
      expect(reopened.status, SyncStatus.pending);
      expect(reopened.retryCount, 0);
      expect(h.collectionRemote.writes, hasLength(1), reason: 'the park');
    });

    test('a retry the server refuses again parks the op again, and says '
        'so', () async {
      final create = await h.queuedCreate(name: 'Smiths');
      await park(create.id);

      expect(await recovery().retry(create.id), isFalse);

      expect((await recovery().watch().first).map((s) => s.entryId), [
        create.id,
      ]);
    });

    test('sends nothing for an op that is not stuck', () async {
      final add = await h.queuedAdd();

      expect(await recovery().retry(add.id), isTrue);

      expect(h.collectionRemote.writes, isEmpty);
      expect((await h.entry(add.id)).status, SyncStatus.pending);
    });
  });

  group('discard', () {
    test('undoes a collection op and refreshes the collection', () async {
      final add = await h.queuedAdd();
      await park(add.id);

      await recovery().discard(add.id);

      expect(await h.collection.getCollection(), isEmpty);
      expect(await h.queue.getAllEntries(), isEmpty);
      expect(collectionRefreshes, 1);
      expect(householdRefreshes, 0);
    });

    test('undoes a household create and refreshes the households', () async {
      final create = await h.queuedCreate(name: 'Smiths');
      await park(create.id);

      await recovery().discard(create.id);

      expect(await h.households.getHouseholds(), isEmpty);
      expect(await h.queue.getAllEntries(), isEmpty);
      expect(householdRefreshes, 1);
      expect(collectionRefreshes, 0);
    });

    test('undoes a stuck event create and refreshes the events', () async {
      final created = await h.events.create(eventDraft());
      await park(created.syncQueueId);

      await recovery().discard(created.syncQueueId);

      expect(await h.events.getEvent(created.event.id), isNull);
      expect(await h.events.watchAttendingEvents().first, isEmpty);
      expect(await h.queue.getAllEntries(), isEmpty);
      expect(eventRefreshes, 1);
      expect(householdRefreshes, 0);
      expect(collectionRefreshes, 0);
    });

    test('deletes an entry that will not decode', () async {
      final garbled = await garbledStuckEntry();

      await recovery().discard(garbled);

      expect(await h.queue.getAllEntries(), isEmpty);
    });

    test('undoes an event create a newer build queued, and refreshes the '
        'events', () async {
      // Another tab, on a newer build, queued it with a type this one can't
      // read. Its local event would otherwise stay on the overview for good.
      final created = await h.events.create(eventDraft());
      await park(created.syncQueueId);
      await h.db.customStatement(
        'UPDATE sync_queue SET payload = ? WHERE id = ?',
        [
          jsonEncode({
            ...created.operation.toJson(),
            'event_type': 'Tournament2027',
          }),
          created.syncQueueId,
        ],
      );
      expect(
        (await recovery().watch().first).single.kind,
        StuckSyncOpKind.unreadable,
      );

      await recovery().discard(created.syncQueueId);

      expect(await h.events.getEvent(created.event.id), isNull);
      expect(await h.events.watchAttendingEvents().first, isEmpty);
      expect(await h.queue.getAllEntries(), isEmpty);
      expect(eventRefreshes, 1);
    });

    test('leaves an op that is not stuck alone', () async {
      final add = await h.queuedAdd();

      await recovery().discard(add.id);

      expect(await h.collection.getCollection(), hasLength(1));
      expect(await h.queue.getAllEntries(), hasLength(1));
      expect(collectionRefreshes, 0);
    });

    test('leaves an unreadable entry alone once it is retried', () async {
      final garbled = await garbledStuckEntry();
      await h.queue.retry(garbled);

      await recovery().discard(garbled);

      expect(await h.queue.getAllEntries(), hasLength(1));
    });
  });
}
