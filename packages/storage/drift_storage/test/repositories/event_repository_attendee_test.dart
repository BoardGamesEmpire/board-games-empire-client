import 'package:drift/drift.dart' show BooleanExpressionOperators, Value;
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/event_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';
import 'package:drift_storage/src/tables/event_access_table.dart'
    show eventAccessSourceAttending, eventAccessSourceHousehold;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../support/event_fixture.dart';
import '../support/fixed_clock.dart';

// An RSVP's answer, cached without a read (#508, #667).

const _kUser = 'user-a';
const _kOther = 'user-b';

final _clock = FixedClockService(DateTime.utc(2026, 10, 28, 12));

void main() {
  late ServerDatabase db;
  late EventRepositoryImpl repo;

  setUp(() {
    db = inMemoryServerDatabase();
    repo = EventRepositoryImpl(
      db,
      userId: _kUser,
      syncQueue: SyncQueueRepositoryImpl(db, _clock, userId: _kUser),
      clock: _clock,
    );
  });

  tearDown(() => db.close());

  final mine = testAttendee('att-a', userId: _kUser, eventId: 'e1');
  final theirs = testAttendee('att-b', userId: _kOther, eventId: 'e1');

  Future<void> cache(EventSnapshot snapshot) =>
      repo.cacheEvent(snapshot, source: EventAccessSource.attending);

  Future<void> cacheWithRoster() =>
      cache(testSnapshot('e1', attendees: [mine, theirs]));

  Future<void> mark(String id, EventsTableCompanion c) =>
      (db.update(db.eventsTable)..where((t) => t.id.equals(id))).write(c);

  EventAttendee maybe(EventAttendee a) => a.copyWith(
    status: EventParticipationStatus.maybe,
    notes: 'Running late.',
  );

  test('replaces the cached row and the detail emits it', () async {
    await cacheWithRoster();
    final emitted = <EventAttendee?>[];
    final sub = repo
        .watchEvent('e1')
        .listen(
          (d) => emitted.add(
            d!.snapshot.attendees!.firstWhere((a) => a.id == mine.id),
          ),
        );
    addTearDown(sub.cancel);
    await pumpEventQueue();
    expect(emitted.last!.status, EventParticipationStatus.attending);

    final answered = maybe(mine);
    expect(await repo.cacheAttendee(answered), isTrue);
    await pumpEventQueue();

    expect(emitted.last!.status, EventParticipationStatus.maybe);
    expect(emitted.last!.notes, 'Running late.');
    final detail = (await repo.watchEvent('e1').first)!;
    expect(detail.attendance!.status, EventParticipationStatus.maybe);
    expect(detail.attendance!.notes, 'Running late.');
  });

  test(
    "updates the attending row's answer for the current user's row",
    () async {
      await cache(
        testSnapshot('e1', attendance: EventAttendance.fromAttendee(mine)),
      );

      expect(await repo.cacheAttendee(maybe(mine)), isTrue);

      final item = (await repo.watchAttendingEventListItems().first).single;
      expect(item.attendance!.status, EventParticipationStatus.maybe);
    },
  );

  test('adds no row to an event with no cached roster', () async {
    await cache(
      testSnapshot('e1', attendance: EventAttendance.fromAttendee(mine)),
    );

    expect(await repo.cacheAttendee(maybe(mine)), isTrue);

    expect((await repo.getEvent('e1'))!.attendees, isNull);
    expect(await db.select(db.eventAttendeesTable).get(), isEmpty);
  });

  test('returns false when neither row is cached', () async {
    // Read by id, so the user has no `attending` row, and no roster.
    await repo.cacheEvent(testSnapshot('e1'), source: EventAccessSource.read);
    final before = await repo.lastWrite('e1');

    expect(await repo.cacheAttendee(maybe(mine)), isFalse);
    expect(await repo.lastWrite('e1'), before);
  });

  test('writes nothing for an uncached, dirty or local-only event', () async {
    expect(await repo.cacheAttendee(maybe(mine)), isFalse);

    await cacheWithRoster();
    // A list row, so the attending row keeps an answer to leave alone.
    await cache(
      testSnapshot('e1', attendance: EventAttendance.fromAttendee(mine)),
    );
    Future<EventAccessTableData> attendingRow() =>
        (db.select(db.eventAccessTable)..where(
              (t) =>
                  t.eventId.equals('e1') &
                  t.userId.equals(_kUser) &
                  t.source.equals(eventAccessSourceAttending),
            ))
            .getSingle();
    final answered = await attendingRow();
    expect(answered.attendeeId, mine.id);
    expect(
      answered.attendanceStatus,
      EventParticipationStatus.attending.toWire(),
    );

    for (final flag in [
      const EventsTableCompanion(isDirty: Value(true)),
      const EventsTableCompanion(
        isDirty: Value(false),
        isLocalOnly: Value(true),
      ),
    ]) {
      await mark('e1', flag);
      final before = await repo.lastWrite('e1');
      expect(before, isNotNull);

      expect(await repo.cacheAttendee(maybe(mine)), isFalse);

      final row = await (db.select(
        db.eventAttendeesTable,
      )..where((t) => t.id.equals(mine.id))).getSingle();
      expect(row.status, EventParticipationStatus.attending.toWire());
      expect(await attendingRow(), answered);
      expect(await repo.lastWrite('e1'), before);
    }
  });

  test(
    "another user's row leaves the current user's attending row alone",
    () async {
      final answer = EventAttendance.fromAttendee(mine);
      await cache(
        testSnapshot('e1', attendees: [mine, theirs], attendance: answer),
      );

      expect(await repo.cacheAttendee(maybe(theirs)), isTrue);

      final item = (await repo.watchAttendingEventListItems().first).single;
      expect(item.attendance, answer);
      final row = await (db.select(
        db.eventAttendeesTable,
      )..where((t) => t.id.equals(theirs.id))).getSingle();
      expect(row.status, EventParticipationStatus.maybe.toWire());
    },
  );

  test('stamps the generation', () async {
    await cacheWithRoster();
    final before = await repo.lastWrite('e1');

    expect(await repo.cacheAttendee(maybe(mine)), isTrue);

    expect(await repo.lastWrite('e1'), isNot(before));
  });

  group('an add or a remove (#510)', () {
    final added = testAttendee('att-c', userId: 'user-c', eventId: 'e1');

    Future<List<String>> rosterIds() async =>
        (await db.select(db.eventAttendeesTable).get())
            .map((r) => r.id)
            .toList()
          ..sort();

    test('addCachedAttendee adds a row to a cached roster', () async {
      await cacheWithRoster();

      expect(await repo.addCachedAttendee(added), isTrue);

      expect(await rosterIds(), ['att-a', 'att-b', 'att-c']);
      final row = await (db.select(
        db.eventAttendeesTable,
      )..where((t) => t.id.equals('att-c'))).getSingle();
      expect(row.displayName, added.displayName);
      expect(row.eventId, 'e1');
    });

    test('addCachedAttendee replaces the row with the same id', () async {
      await cacheWithRoster();

      expect(await repo.addCachedAttendee(maybe(theirs)), isTrue);

      expect(await rosterIds(), ['att-a', 'att-b']);
      final row = await (db.select(
        db.eventAttendeesTable,
      )..where((t) => t.id.equals('att-b'))).getSingle();
      expect(row.status, EventParticipationStatus.maybe.toWire());
      expect(row.notes, 'Running late.');
    });

    test('addCachedAttendee writes nothing with no roster cached', () async {
      await cache(testSnapshot('e1'));
      final before = await repo.lastWrite('e1');

      expect(await repo.addCachedAttendee(added), isFalse);

      expect(await rosterIds(), isEmpty);
      expect(await repo.lastWrite('e1'), before);
    });

    test(
      'addCachedAttendee writes nothing for a dirty or local-only event',
      () async {
        expect(await repo.addCachedAttendee(added), isFalse);

        await cacheWithRoster();
        for (final flag in [
          const EventsTableCompanion(isDirty: Value(true)),
          const EventsTableCompanion(
            isDirty: Value(false),
            isLocalOnly: Value(true),
          ),
        ]) {
          await mark('e1', flag);
          final before = await repo.lastWrite('e1');

          expect(await repo.addCachedAttendee(added), isFalse);

          expect(await rosterIds(), ['att-a', 'att-b']);
          expect(await repo.lastWrite('e1'), before);
        }
      },
    );

    test("addCachedAttendee puts the user's own answer on the household's "
        'list', () async {
      // A household owner or admin who isn't on the roster can find and add
      // themselves.
      await repo.cacheEvent(
        testSnapshot('e1', attendees: [theirs]),
        source: EventAccessSource.household,
      );
      final joined = mine.copyWith(status: EventParticipationStatus.invited);

      expect(await repo.addCachedAttendee(joined), isTrue);

      final item =
          (await repo.watchHouseholdEventListItems('household-1').first).single;
      expect(item.attendance, EventAttendance.fromAttendee(joined));
      // From their `household` access, which the list reads before the
      // roster.
      final access =
          await (db.select(db.eventAccessTable)..where(
                (t) =>
                    t.eventId.equals('e1') &
                    t.userId.equals(_kUser) &
                    t.source.equals(eventAccessSourceHousehold),
              ))
              .getSingle();
      expect(access.attendeeId, joined.id);
      expect(
        access.attendanceStatus,
        EventParticipationStatus.invited.toWire(),
      );
    });

    test('addCachedAttendee puts an event the user added themselves to on '
        'their attending list', () async {
      // The server lists every event the user is on, so it does from the
      // add, and the list needn't wait for the next hydrate to show it.
      await repo.cacheEvent(
        testSnapshot('e1', attendees: [theirs]),
        source: EventAccessSource.household,
      );
      expect(await repo.watchAttendingEventListItems().first, isEmpty);
      final joined = mine.copyWith(status: EventParticipationStatus.invited);

      expect(await repo.addCachedAttendee(joined), isTrue);

      final item = (await repo.watchAttendingEventListItems().first).single;
      expect(item.event.id, 'e1');
      expect(item.attendance, EventAttendance.fromAttendee(joined));
    });

    test(
      "adding someone else leaves the user's attending list alone",
      () async {
        await repo.cacheEvent(
          testSnapshot('e1', attendees: [theirs]),
          source: EventAccessSource.household,
        );

        expect(await repo.addCachedAttendee(added), isTrue);

        expect(await repo.watchAttendingEventListItems().first, isEmpty);
        final attending = await (db.select(
          db.eventAccessTable,
        )..where((t) => t.source.equals(eventAccessSourceAttending))).get();
        expect(attending, isEmpty);
      },
    );

    test('removeCachedAttendee removes the row', () async {
      await cacheWithRoster();
      final before = await repo.lastWrite('e1');

      expect(
        await repo.removeCachedAttendee(eventId: 'e1', attendeeId: 'att-b'),
        isTrue,
      );

      expect(await rosterIds(), ['att-a']);
      expect(await repo.lastWrite('e1'), isNot(before));
    });

    test('removeCachedAttendee answers false for a row not cached', () async {
      await cacheWithRoster();
      final before = await repo.lastWrite('e1');

      expect(
        await repo.removeCachedAttendee(eventId: 'e1', attendeeId: 'nope'),
        isFalse,
      );
      expect(
        await repo.removeCachedAttendee(eventId: 'e2', attendeeId: 'att-b'),
        isFalse,
      );

      expect(await rosterIds(), ['att-a', 'att-b']);
      expect(await repo.lastWrite('e1'), before);
    });

    test('removeCachedAttendee writes nothing for a dirty event', () async {
      await cacheWithRoster();
      await mark('e1', const EventsTableCompanion(isDirty: Value(true)));

      expect(
        await repo.removeCachedAttendee(eventId: 'e1', attendeeId: 'att-b'),
        isFalse,
      );
      expect(await rosterIds(), ['att-a', 'att-b']);
    });

    test('watchEvent emits after each', () async {
      await cacheWithRoster();
      final rosters = <List<String>>[];
      final sub = repo
          .watchEvent('e1')
          .listen(
            (d) => rosters.add(
              d!.snapshot.attendees!.map((a) => a.id).toList()..sort(),
            ),
          );
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(rosters.last, ['att-a', 'att-b']);

      await repo.addCachedAttendee(added);
      await pumpEventQueue();
      expect(rosters.last, ['att-a', 'att-b', 'att-c']);

      await repo.removeCachedAttendee(eventId: 'e1', attendeeId: 'att-c');
      await pumpEventQueue();
      expect(rosters.last, ['att-a', 'att-b']);
    });
  });
}
