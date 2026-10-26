import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/event_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';
import 'package:drift_storage/src/tables/event_access_table.dart'
    show eventAccessSourceRead;

import '../support/event_fixture.dart';
import '../support/fixed_clock.dart';

// A queued event create (#499): the local-only event and its op, written in
// one transaction; the reconcile that replaces the event with the server's;
// and the discard of a create the server refused. Over a real queue on the
// same database, so the op and its completion are the queue's own.

const _kUserA = 'user-a';
const _kUserB = 'user-b';
final _now = DateTime.utc(2026, 10, 26, 12);

/// A queue whose enqueue fails, as a database error would. A create calls
/// nothing else on it.
class _EnqueueFails implements SyncQueueRepository {
  @override
  Future<SyncQueueEntry> enqueue(SyncOperation operation) async =>
      throw Exception('the queue is gone');

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not in a create');
}

void main() {
  late ServerDatabase db;
  late FixedClockService clock;
  late SyncQueueRepositoryImpl queue;
  late EventRepositoryImpl repo;

  /// A repository for [userId] over the same database, with its own queue,
  /// as another session or another web tab holds.
  EventRepositoryImpl repoFor(String userId) => EventRepositoryImpl(
    db,
    userId: userId,
    syncQueue: SyncQueueRepositoryImpl(db, clock, userId: userId),
    clock: clock,
  );

  setUp(() {
    db = inMemoryServerDatabase();
    clock = FixedClockService(_now);
    queue = SyncQueueRepositoryImpl(db, clock, userId: _kUserA);
    repo = EventRepositoryImpl(
      db,
      userId: _kUserA,
      syncQueue: queue,
      clock: clock,
    );
  });

  tearDown(() => db.close());

  final friday = DateTime.utc(2026, 11, 6, 18);
  final nextFriday = DateTime.utc(2026, 11, 13, 18);

  /// A Fixed event on [friday].
  EventDraft fixedDraft({String title = 'Game night'}) => EventDraft(
    title: title,
    occurrences: [
      EventOccurrenceDraft(
        label: 'The night',
        startDate: friday,
        endDate: friday.add(const Duration(hours: 4)),
        location: 'Back room',
      ),
    ],
  );

  /// What the server answers the create of [fixedDraft] with, under [id]: the
  /// creator as host and user-b invited, with no names, since the create's
  /// roster embeds each attendee's role and not their user.
  EventSnapshot serverCopy({
    String id = 'ev-server',
    String title = 'Game night',
  }) {
    EventAttendee unnamed(EventAttendee a) =>
        a.copyWith(username: null, displayName: null, avatarUrl: null);
    return testSnapshot(
      id,
      title: title,
      policy: testPolicy(id: 'pol-$id', eventId: id),
      attendees: [
        unnamed(
          testAttendee(
            'att-a',
            userId: _kUserA,
            eventId: id,
          ).copyWith(role: EventRole.host),
        ),
        unnamed(
          testAttendee(
            'att-b',
            userId: _kUserB,
            eventId: id,
          ).copyWith(status: EventParticipationStatus.invited),
        ),
      ],
    );
  }

  Future<SyncQueueEntry> entry(String id) async =>
      (await queue.getAllEntries()).singleWhere((e) => e.id == id);

  Future<List<EventMovesTableData>> moves() =>
      db.select(db.eventMovesTable).get();

  /// The events each table beside `events` holds rows for.
  Future<Map<String, Set<String>>> childEventIds() async => {
    'event_occurrences': {
      for (final r in await db.select(db.eventOccurrencesTable).get())
        r.eventId,
    },
    'event_attendees': {
      for (final r in await db.select(db.eventAttendeesTable).get()) r.eventId,
    },
    'event_policies': {
      for (final r in await db.select(db.eventPoliciesTable).get()) r.eventId,
    },
    'event_access': {
      for (final r in await db.select(db.eventAccessTable).get()) r.eventId,
    },
  };

  group('create', () {
    test('create writes a local-only event the overview lists', () async {
      final created = await repo.create(fixedDraft());

      final items = await repo.watchAttendingEventListItems().first;
      expect(items, hasLength(1));
      final item = items.single;
      expect(item.event, created.event);
      expect(item.event.isLocalOnly, isTrue);
      expect(item.event.isDirty, isTrue);
      expect(item.event.title, 'Game night');
      expect(item.event.createdById, _kUserA);
      expect(item.event.createdAt, _now);
      expect(item.event.updatedAt, _now);
      expect(item.attendance?.userId, _kUserA);
      expect(item.attendance?.role, EventRole.host);
      expect(item.attendance?.status, EventParticipationStatus.attending);
    });

    test('create enqueues one op keyed by the event\'s id', () async {
      final created = await repo.create(fixedDraft(title: '  Game night  '));

      final pending = await queue.getPendingEntries();
      expect(pending, hasLength(1));
      expect(pending.single.id, created.syncQueueId);
      final op = pending.single.operation as CreateEventOperation;
      expect(op.localId, created.event.id);
      expect(op.draft.title, 'Game night');
      expect(created.event.title, 'Game night');
      // An inline send of the returned op carries what a drain would send
      // from the entry.
      expect(created.operation.serialized, pending.single.payload);
    });

    test('create writes its fields, and no policy and no invitees', () async {
      final created = await repo.create(
        fixedDraft().copyWith(
          householdId: 'hh-server',
          description: 'Bring snacks.',
          location: 'Kitchen table',
          url: 'https://example.test/e',
          type: EventType.strategyNight,
          reach: Reach.public,
          inviteUserIds: const [_kUserB],
        ),
      );

      final snapshot = await repo.getEvent(created.event.id);
      final event = snapshot!.event;
      expect(event.householdId, 'hh-server');
      expect(event.description, 'Bring snacks.');
      expect(event.location, 'Kitchen table');
      expect(event.url, 'https://example.test/e');
      expect(event.type, EventType.strategyNight);
      expect(event.reach, Reach.public);
      expect(event.schedulingMode, EventSchedulingMode.fixed);
      // The reconcile brings both.
      expect(snapshot.policy, isNull);
      expect(snapshot.attendees?.map((a) => a.userId), [_kUserA]);
    });

    test('a poll\'s dates are proposed and it is planning', () async {
      final created = await repo.create(
        EventDraft(
          title: 'Which Friday?',
          schedulingMode: EventSchedulingMode.poll,
          occurrences: [
            EventOccurrenceDraft(label: 'First', startDate: friday),
            EventOccurrenceDraft(label: 'Second', startDate: nextFriday),
          ],
        ),
      );

      final snapshot = await repo.getEvent(created.event.id);
      expect(snapshot!.event.status, EventStatus.planning);
      final occurrences = snapshot.occurrences;
      expect(occurrences.map((o) => o.label), ['First', 'Second']);
      expect(occurrences.map((o) => o.startDate), [friday, nextFriday]);
      expect(
        occurrences.map((o) => o.status),
        everyElement(OccurrenceStatus.proposed),
      );
      expect(occurrences.map((o) => o.confirmedAt), everyElement(isNull));
      expect(occurrences.map((o) => o.sortOrder), [0, 1]);
      expect(occurrences.map((o) => o.eventId), everyElement(created.event.id));
      expect(occurrences.map((o) => o.id).toSet(), hasLength(2));
    });

    test('a fixed date is confirmed and scheduled', () async {
      final created = await repo.create(fixedDraft());

      final snapshot = await repo.getEvent(created.event.id);
      expect(snapshot!.event.status, EventStatus.scheduled);
      final occurrence = snapshot.occurrences.single;
      expect(occurrence.status, OccurrenceStatus.confirmed);
      expect(occurrence.confirmedAt, _now);
      expect(occurrence.sortOrder, 0);
      expect(occurrence.label, 'The night');
      expect(occurrence.startDate, friday);
      expect(occurrence.endDate, friday.add(const Duration(hours: 4)));
      expect(occurrence.location, 'Back room');
    });

    test('an event with no type or reach is cached as a casual gathering '
        'for friends', () async {
      final created = await repo.create(fixedDraft());

      expect(created.event.type, EventType.casualGathering);
      expect(created.event.reach, Reach.friends);
      // The op leaves both out, so the server's defaults apply.
      expect(created.operation.draft.type, isNull);
      expect(created.operation.draft.reach, isNull);
    });

    test('create refuses what the server would, and writes nothing', () async {
      // A household created here that the server has yet to confirm: its id
      // is one the server has never heard of.
      await db
          .into(db.householdsTable)
          .insert(
            HouseholdsTableCompanion.insert(
              id: 'hh-local',
              name: 'Smiths',
              isDirty: const Value(true),
              isLocalOnly: const Value(true),
              createdAt: _now,
              updatedAt: _now,
            ),
          );

      final refused = <String, EventDraft>{
        'a blank title': fixedDraft(title: '   '),
        'two dates on a Fixed event': EventDraft(
          title: 'Game night',
          occurrences: [
            EventOccurrenceDraft(startDate: friday),
            EventOccurrenceDraft(startDate: nextFriday),
          ],
        ),
        '51 invitees': fixedDraft().copyWith(
          inviteUserIds: [
            for (var i = 0; i <= EventDraft.maxInvitees; i++) 'user-$i',
          ],
        ),
        'Reach.unknown': fixedDraft().copyWith(reach: Reach.unknown),
        'a Supermajority threshold with no value': fixedDraft().copyWith(
          policy: const EventPolicyDraft(
            voteThresholdType: VoteThresholdType.supermajority,
          ),
        ),
        'a voting window of 0 hours': fixedDraft().copyWith(
          policy: const EventPolicyDraft(votingWindowHours: 0),
        ),
        'a local-only household': fixedDraft().copyWith(
          householdId: 'hh-local',
        ),
        'an empty household id': fixedDraft().copyWith(householdId: ''),
      };

      for (final MapEntry(key: reason, value: draft) in refused.entries) {
        await expectLater(
          repo.create(draft),
          throwsArgumentError,
          reason: reason,
        );
      }

      expect(await db.select(db.eventsTable).get(), isEmpty);
      expect(await db.select(db.eventAccessTable).get(), isEmpty);
      expect(await queue.getAllEntries(), isEmpty);
    });

    test('a household created here whose create has landed since is sent '
        'under the server\'s id', () async {
      // The form was opened on the local id, and the household's reconcile
      // replaced it before the event was submitted.
      await db
          .into(db.householdMovesTable)
          .insert(
            HouseholdMovesTableCompanion.insert(
              localId: 'hh-local',
              serverId: 'hh-server',
            ),
          );

      final created = await repo.create(
        fixedDraft().copyWith(householdId: 'hh-local'),
      );

      expect(created.event.householdId, 'hh-server');
      expect(created.operation.draft.householdId, 'hh-server');
      final queued = (await entry(created.syncQueueId)).operation;
      expect((queued as CreateEventOperation).draft.householdId, 'hh-server');
    });

    test('a household reconciled while the create reads it is never sent '
        'under its local id', () async {
      await db
          .into(db.householdsTable)
          .insert(
            HouseholdsTableCompanion.insert(
              id: 'hh-local',
              name: 'Smiths',
              isDirty: const Value(true),
              isLocalOnly: const Value(true),
              createdAt: _now,
              updatedAt: _now,
            ),
          );

      // The household's reconcile, which deletes the local row and records
      // where it went in one commit, lands while the create is reading it.
      final creating = repo.create(
        fixedDraft().copyWith(householdId: 'hh-local'),
      );
      final reconciling = db.transaction(() async {
        await (db.delete(
          db.householdsTable,
        )..where((t) => t.id.equals('hh-local'))).go();
        await db
            .into(db.householdMovesTable)
            .insert(
              HouseholdMovesTableCompanion.insert(
                localId: 'hh-local',
                serverId: 'hh-server',
              ),
            );
      });

      // Read before it, the household is refused as unconfirmed; read after
      // it, it is sent under the server's id. The id the server has never
      // heard of is never queued.
      String? sent;
      try {
        sent = (await creating).operation.draft.householdId;
      } on ArgumentError {
        sent = null;
      }
      await reconciling;
      expect(sent, isNot('hh-local'));
      for (final e in await queue.getAllEntries()) {
        expect(
          (e.operation as CreateEventOperation).draft.householdId,
          isNot('hh-local'),
        );
      }
    });

    test('create writes nothing when the enqueue throws', () async {
      final failing = EventRepositoryImpl(
        db,
        userId: _kUserA,
        syncQueue: _EnqueueFails(),
        clock: clock,
      );

      await expectLater(failing.create(fixedDraft()), throwsException);

      expect(await db.select(db.eventsTable).get(), isEmpty);
      expect(await db.select(db.eventOccurrencesTable).get(), isEmpty);
      expect(await db.select(db.eventAttendeesTable).get(), isEmpty);
      expect(await db.select(db.eventAccessTable).get(), isEmpty);
      expect(await db.select(db.eventGenerationTable).get(), isEmpty);
    });

    test('create stamps a generation, as every write does', () async {
      await repo.cacheEvent(
        testSnapshot('ev-cached'),
        source: EventAccessSource.attending,
      );
      final before = await repo.lastWrite('ev-cached');

      final created = await repo.create(fixedDraft());

      expect(await repo.lastWrite(created.event.id), greaterThan(before!));
    });

    test('another user never sees a local event', () async {
      final created = await repo.create(fixedDraft());
      final b = repoFor(_kUserB);

      expect(await b.getEvent(created.event.id), isNull);
      expect(await b.getCurrentUserAttendance(created.event.id), isNull);
      expect(await b.watchAttendingEventListItems().first, isEmpty);
      expect(await b.watchAttendingEvents().first, isEmpty);
      expect(await b.watchEvent(created.event.id).first, isNull);
    });
  });

  group('reconcileCreatedEvent', () {
    test('reconcile replaces the local event with the server\'s', () async {
      final created = await repo.create(fixedDraft());
      final server = serverCopy();

      await repo.reconcileCreatedEvent(
        server,
        localId: created.event.id,
        deleted: false,
        completedSyncQueueId: created.syncQueueId,
      );

      expect(await repo.getEvent(created.event.id), isNull);
      final cached = await repo.getEvent('ev-server');
      expect(cached!.attendees, server.attendees);
      expect(cached.occurrences, server.occurrences);
      expect(cached.policy, server.policy);
      expect(cached.event.isLocalOnly, isFalse);
      expect(cached.event.isDirty, isFalse);
      expect(repo.reconciledEventId(created.event.id), 'ev-server');
      expect((await entry(created.syncQueueId)).status, SyncStatus.completed);
      expect((await moves()).map((m) => (m.localId, m.serverId)), [
        (created.event.id, 'ev-server'),
      ]);

      // Nothing of the local event is left behind.
      expect((await repo.watchAttendingEvents().first).map((e) => e.id), [
        'ev-server',
      ]);
      expect(await childEventIds(), {
        'event_occurrences': {'ev-server'},
        'event_attendees': {'ev-server'},
        'event_policies': {'ev-server'},
        'event_access': {'ev-server'},
      });
    });

    test('reconcile over a server copy the hydrate already cached', () async {
      final created = await repo.create(fixedDraft());
      // A pass that ran before the create's acknowledgement, and a detail
      // read with it: the same roster rows the reconcile brings.
      final server = serverCopy(title: 'From the create');
      await repo.cacheEvent(
        serverCopy(title: 'From the hydrate'),
        source: EventAccessSource.attending,
      );
      expect(await repo.watchAttendingEvents().first, hasLength(2));

      await repo.reconcileCreatedEvent(
        server,
        localId: created.event.id,
        deleted: false,
        completedSyncQueueId: created.syncQueueId,
      );

      final events = await repo.watchAttendingEvents().first;
      expect(events.map((e) => e.id), ['ev-server']);
      final cached = await repo.getEvent('ev-server');
      expect(cached!.event.title, 'From the create');
      expect(cached.attendees, server.attendees);
      expect(await db.select(db.eventsTable).get(), hasLength(1));
      expect((await entry(created.syncQueueId)).status, SyncStatus.completed);
    });

    test('reconcile of a deleted replay leaves no event and records no '
        'move', () async {
      final created = await repo.create(fixedDraft());

      await repo.reconcileCreatedEvent(
        serverCopy(),
        localId: created.event.id,
        deleted: true,
        completedSyncQueueId: created.syncQueueId,
      );

      expect(await repo.getEvent(created.event.id), isNull);
      expect(await repo.getEvent('ev-server'), isNull);
      expect(repo.reconciledEventId(created.event.id), isNull);
      expect(await moves(), isEmpty);
      expect(await db.select(db.eventsTable).get(), isEmpty);
      expect((await entry(created.syncQueueId)).status, SyncStatus.completed);
    });

    test('a deleted replay removes the copy a hydrate cached under the '
        'server\'s id, for every user', () async {
      // The create's answer was lost, a hydrate cached the event it made,
      // and it was deleted before the retry replayed the create.
      final created = await repo.create(fixedDraft());
      await repo.cacheEvent(serverCopy(), source: EventAccessSource.attending);
      final b = repoFor(_kUserB);
      await b.cacheEvent(serverCopy(), source: EventAccessSource.read);

      await repo.reconcileCreatedEvent(
        serverCopy(),
        localId: created.event.id,
        deleted: true,
        completedSyncQueueId: created.syncQueueId,
      );

      expect(await repo.getEvent('ev-server'), isNull);
      expect(await b.getEvent('ev-server'), isNull);
      expect(await repo.watchAttendingEvents().first, isEmpty);
      expect(await db.select(db.eventsTable).get(), isEmpty);
      expect(await childEventIds(), {
        'event_occurrences': <String>{},
        'event_attendees': <String>{},
        'event_policies': <String>{},
        'event_access': <String>{},
      });
      expect((await entry(created.syncQueueId)).status, SyncStatus.completed);
    });

    test('reconcile under the local id clears the flags and records no '
        'move', () async {
      // A move to itself would have a screen follow itself forever.
      final created = await repo.create(fixedDraft());
      final server = serverCopy(id: created.event.id, title: 'Confirmed');

      await repo.reconcileCreatedEvent(
        server,
        localId: created.event.id,
        deleted: false,
        completedSyncQueueId: created.syncQueueId,
      );

      final cached = await repo.getEvent(created.event.id);
      expect(cached!.event.isLocalOnly, isFalse);
      expect(cached.event.isDirty, isFalse);
      expect(cached.event.title, 'Confirmed');
      expect(cached.occurrences, server.occurrences);
      expect(cached.attendees, server.attendees);
      expect(repo.reconciledEventId(created.event.id), isNull);
      expect(await moves(), isEmpty);
      expect((await entry(created.syncQueueId)).status, SyncStatus.completed);
    });

    test('a replay with no roster and no policy caches the event without '
        'them', () async {
      // The creator has lost read on the event since: the replay reads its
      // parts as they may read them now.
      final created = await repo.create(fixedDraft());

      await repo.reconcileCreatedEvent(
        serverCopy().copyWith(attendees: const [], policy: null),
        localId: created.event.id,
        deleted: false,
        completedSyncQueueId: created.syncQueueId,
      );

      final cached = await repo.getEvent('ev-server');
      expect(cached!.attendees, isNull);
      expect(cached.policy, isNull);
      expect(await repo.getEvent(created.event.id), isNull);
      expect(repo.reconciledEventId(created.event.id), 'ev-server');
      // Not on the roster, so not attending it: it is no longer listed.
      expect(await repo.watchAttendingEvents().first, isEmpty);
    });

    test('a replay whose roster leaves the creator off is read, not '
        'attended', () async {
      // The creator left the event, from another device, before the retry
      // replayed the create.
      final created = await repo.create(fixedDraft());
      final server = serverCopy();

      await repo.reconcileCreatedEvent(
        server.copyWith(
          attendees: [
            for (final a in server.attendees!)
              if (a.userId != _kUserA) a,
          ],
        ),
        localId: created.event.id,
        deleted: false,
        completedSyncQueueId: created.syncQueueId,
      );

      expect(await repo.watchAttendingEvents().first, isEmpty);
      expect(await repo.getEvent('ev-server'), isNotNull);
      expect(
        (await db.select(db.eventAccessTable).get()).map(
          (a) => (a.eventId, a.source),
        ),
        [('ev-server', eventAccessSourceRead)],
      );
    });

    test('a replay whose roster leaves the creator off takes back the '
        'attendance a hydrate cached', () async {
      // A hydrate cached the event as attended after the create's answer
      // was lost, and the creator left it before the retry replayed it.
      final created = await repo.create(fixedDraft());
      final server = serverCopy();
      await repo.cacheEvent(server, source: EventAccessSource.attending);

      await repo.reconcileCreatedEvent(
        server.copyWith(
          attendees: [
            for (final a in server.attendees!)
              if (a.userId != _kUserA) a,
          ],
        ),
        localId: created.event.id,
        deleted: false,
        completedSyncQueueId: created.syncQueueId,
      );

      expect(await repo.watchAttendingEvents().first, isEmpty);
      expect(await repo.watchAttendingEventListItems().first, isEmpty);
      expect(await repo.getEvent('ev-server'), isNotNull);
      expect(
        (await db.select(db.eventAccessTable).get()).map(
          (a) => (a.eventId, a.source),
        ),
        [('ev-server', eventAccessSourceRead)],
      );
    });

    test('reconcile keeps the names a cached roster gave', () async {
      // The create's answer was lost, and a detail read cached the event,
      // names and all, before the retry's replay.
      final created = await repo.create(fixedDraft());
      final server = serverCopy();
      final named = [
        testAttendee(
          'att-a',
          userId: _kUserA,
          eventId: 'ev-server',
        ).copyWith(role: EventRole.host),
        testAttendee('att-b', userId: _kUserB, eventId: 'ev-server'),
      ];
      await repo.cacheEvent(
        server.copyWith(attendees: named),
        source: EventAccessSource.attending,
      );

      await repo.reconcileCreatedEvent(
        server,
        localId: created.event.id,
        deleted: false,
        completedSyncQueueId: created.syncQueueId,
      );

      final roster = (await repo.getEvent('ev-server'))!.attendees!;
      expect(roster.map((a) => (a.id, a.username, a.displayName)), [
        ('att-a', 'name-$_kUserA', 'Display $_kUserA'),
        ('att-b', 'name-$_kUserB', 'Display $_kUserB'),
      ]);
      // The rest is the answer's.
      expect(
        roster.map((a) => (a.status, a.role)),
        server.attendees!.map((a) => (a.status, a.role)),
      );
    });

    test(
      'leaves the queue alone when no completedSyncQueueId is given',
      () async {
        final created = await repo.create(fixedDraft());

        await repo.reconcileCreatedEvent(
          serverCopy(),
          localId: created.event.id,
          deleted: false,
        );

        expect((await entry(created.syncQueueId)).status, SyncStatus.pending);
      },
    );

    test('records nothing when the reconcile rolls back', () async {
      final created = await repo.create(fixedDraft());
      // The session scope popping between send and reconcile: completing
      // the entry throws inside the transaction.
      await queue.onDispose();

      await expectLater(
        repo.reconcileCreatedEvent(
          serverCopy(),
          localId: created.event.id,
          deleted: false,
          completedSyncQueueId: created.syncQueueId,
        ),
        throwsStateError,
      );

      expect(repo.reconciledEventId(created.event.id), isNull);
      expect(await moves(), isEmpty);
      final local = await repo.getEvent(created.event.id);
      expect(local!.event.isLocalOnly, isTrue);
      expect(await repo.getEvent('ev-server'), isNull);
    });
  });

  group('the id it records', () {
    test('another repository over the same database finds the move', () async {
      final created = await repo.create(fixedDraft());
      await repo.reconcileCreatedEvent(
        serverCopy(),
        localId: created.event.id,
        deleted: false,
        completedSyncQueueId: created.syncQueueId,
      );
      final other = repoFor(_kUserA);

      // Nothing read yet: the detail recovers on the first emission.
      expect(other.reconciledEventId(created.event.id), isNull);
      expect(await other.watchEvent(created.event.id).first, isNull);
      expect(other.reconciledEventId(created.event.id), 'ev-server');
    });

    test('a detail open on the local id in another repository sees the move '
        'on the emission that drops it', () async {
      // The detail asks on every emission, and the one without the event
      // must already answer, or it shows not-found.
      final created = await repo.create(fixedDraft());
      final other = repoFor(_kUserA);
      final seen = <({bool found, String? answer})>[];
      final sub = other
          .watchEvent(created.event.id)
          .listen(
            (detail) => seen.add((
              found: detail != null,
              answer: other.reconciledEventId(created.event.id),
            )),
          );
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(seen.single.found, isTrue);

      await repo.reconcileCreatedEvent(
        serverCopy(),
        localId: created.event.id,
        deleted: false,
        completedSyncQueueId: created.syncQueueId,
      );
      await pumpEventQueue();

      expect(seen.last, (found: false, answer: 'ev-server'));
    });

    test('a detail of another event emits nothing more for the '
        'reconcile', () async {
      // Each emission reads the moves too, and must still drop a detail
      // that reads as it did.
      await repo.cacheEvent(
        testSnapshot('ev-other'),
        source: EventAccessSource.attending,
      );
      final created = await repo.create(fixedDraft());
      final emissions = <EventDetail?>[];
      final sub = repo.watchEvent('ev-other').listen(emissions.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      await repo.reconcileCreatedEvent(
        serverCopy(),
        localId: created.event.id,
        deleted: false,
        completedSyncQueueId: created.syncQueueId,
      );
      await pumpEventQueue();

      expect(emissions, hasLength(1));
    });

    test('answers null for an id nothing reconciled', () async {
      final created = await repo.create(fixedDraft());

      expect(repo.reconciledEventId(created.event.id), isNull);
    });
  });

  group('discardQueuedOp', () {
    test('discard removes a parked create and its event', () async {
      final kept = await repo.create(fixedDraft(title: 'Kept'));
      final created = await repo.create(fixedDraft());
      await queue.park(created.syncQueueId, error: 'refused: 403');

      expect(await repo.discardQueuedOp(created.syncQueueId), isTrue);

      expect(await repo.getEvent(created.event.id), isNull);
      expect((await repo.watchAttendingEvents().first).map((e) => e.id), [
        kept.event.id,
      ]);
      expect(await childEventIds(), {
        'event_occurrences': {kept.event.id},
        'event_attendees': {kept.event.id},
        'event_policies': <String>{},
        'event_access': {kept.event.id},
      });
      expect((await queue.getAllEntries()).map((e) => e.id), [
        kept.syncQueueId,
      ]);
    });

    test('discard of an op that isn\'t stuck changes nothing', () async {
      final created = await repo.create(fixedDraft());

      expect(await repo.discardQueuedOp(created.syncQueueId), isFalse);

      expect(await repo.getEvent(created.event.id), isNotNull);
      expect(await queue.getAllEntries(), hasLength(1));
    });

    test('discard of a completed or unknown entry changes nothing', () async {
      final created = await repo.create(fixedDraft());
      await queue.markCompleted(created.syncQueueId);

      expect(await repo.discardQueuedOp(created.syncQueueId), isFalse);
      expect(await repo.discardQueuedOp('nonexistent'), isFalse);

      expect(await repo.getEvent(created.event.id), isNotNull);
      expect(await queue.getAllEntries(), hasLength(1));
    });

    test('discard of a create this build can\'t read removes its event '
        'too', () async {
      // Queued by a newer build, in another tab, with a type this one
      // doesn't know. Nothing else would ever remove the local event.
      final created = await repo.create(fixedDraft());
      await queue.park(created.syncQueueId, error: 'refused: 400');
      await db.customStatement(
        'UPDATE sync_queue SET payload = ? WHERE id = ?',
        [
          jsonEncode(
            created.operation.toJson()..['event_type'] = 'Tournament2027',
          ),
          created.syncQueueId,
        ],
      );
      final unreadable = await entry(created.syncQueueId);
      expect(() => unreadable.operation, throwsFormatException);

      expect(await repo.discardQueuedOp(created.syncQueueId), isTrue);

      expect(await repo.getEvent(created.event.id), isNull);
      expect(await db.select(db.eventsTable).get(), isEmpty);
      expect(await queue.getAllEntries(), isEmpty);
    });

    test('discard of an entry that won\'t decode at all deletes only the '
        'entry', () async {
      final created = await repo.create(fixedDraft());
      await queue.park(created.syncQueueId, error: 'refused: 400');
      await db.customStatement(
        'UPDATE sync_queue SET payload = ? WHERE id = ?',
        ['{not json', created.syncQueueId],
      );

      expect(await repo.discardQueuedOp(created.syncQueueId), isTrue);

      expect(await queue.getAllEntries(), isEmpty);
      // Nothing in the payload names the local event any longer.
      expect(await repo.getEvent(created.event.id), isNotNull);
    });

    test('discard of a household op throws ArgumentError', () async {
      final household = await queue.enqueue(
        const CreateHouseholdOperation(localId: 'hh-local', name: 'Smiths'),
      );
      await queue.park(household.id, error: 'refused: 403');

      await expectLater(
        repo.discardQueuedOp(household.id),
        throwsArgumentError,
      );

      expect(await queue.getAllEntries(), hasLength(1));
    });
  });

  test('create, reconcile and discard throw after dispose, and '
      'reconciledEventId does not', () async {
    final reconciled = await repo.create(fixedDraft());
    await repo.reconcileCreatedEvent(
      serverCopy(),
      localId: reconciled.event.id,
      deleted: false,
      completedSyncQueueId: reconciled.syncQueueId,
    );
    final created = await repo.create(fixedDraft());
    await queue.park(created.syncQueueId, error: 'refused: 403');

    await repo.onDispose();

    await expectLater(repo.create(fixedDraft()), throwsStateError);
    await expectLater(
      repo.reconcileCreatedEvent(
        serverCopy(id: 'ev-second'),
        localId: created.event.id,
        deleted: false,
      ),
      throwsStateError,
    );
    await expectLater(
      repo.discardQueuedOp(created.syncQueueId),
      throwsStateError,
    );
    expect(repo.reconciledEventId(reconciled.event.id), 'ev-server');
    expect(repo.reconciledEventId(created.event.id), isNull);
  });
}
