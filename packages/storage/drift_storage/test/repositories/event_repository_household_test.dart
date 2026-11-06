import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/event_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';

import '../support/event_fixture.dart';
import '../support/fixed_clock.dart';

// The household list's cache (#503): its events are held under their own
// `household` access, listed per household, and purged against page 1 of the
// household's list without touching any other access the user has.

const _kUserA = 'user-a';
const _kUserB = 'user-b';

final _clock = FixedClockService(DateTime.utc(2026, 10, 26, 12));

void main() {
  late ServerDatabase db;
  late EventRepositoryImpl a;

  EventRepositoryImpl repoFor(String userId) => EventRepositoryImpl(
    db,
    userId: userId,
    syncQueue: SyncQueueRepositoryImpl(db, _clock, userId: userId),
    clock: _clock,
  );

  setUp(() {
    db = inMemoryServerDatabase();
    a = repoFor(_kUserA);
  });

  tearDown(() => db.close());

  Future<void> cache(
    String id, {
    String householdId = 'household-1',
    EventRepositoryImpl? repo,
    EventAttendance? attendance,
    List<EventOccurrence>? occurrences,
  }) => (repo ?? a).cacheEvent(
    testSnapshot(
      id,
      householdId: householdId,
      attendance: attendance,
      occurrences: occurrences,
    ),
    source: EventAccessSource.household,
  );

  Future<List<String>> listed(
    String householdId, {
    EventRepositoryImpl? repo,
  }) async => [
    for (final item
        in await (repo ?? a).watchHouseholdEventListItems(householdId).first)
      item.event.id,
  ];

  Future<void> markDirty(String id) =>
      (db.update(db.eventsTable)..where((t) => t.id.equals(id))).write(
        const EventsTableCompanion(isDirty: Value(true)),
      );

  Future<Set<String>> purge(String householdId, Set<String> ids) async {
    final p = await a.purgeableHouseholdEvents(householdId);
    return a.purgeHouseholdEventsAbsentFrom(householdId, ids, purgeable: p);
  }

  test('a household row is listed for its household only', () async {
    await cache('e-1');
    await cache('e-2', householdId: 'household-2');

    expect(await listed('household-1'), ['e-1']);
  });

  test('a household row is not on the attending list', () async {
    await cache('e-1');

    expect(await a.watchAttendingEventListItems().first, isEmpty);
  });

  test("another user's household row is not listed", () async {
    await cache('e-1', repo: repoFor(_kUserB));

    expect(await listed('household-1'), isEmpty);
  });

  test('the answer is written onto an attending row, null included, and '
      'never adds one', () async {
    const mine = EventAttendance(
      attendeeId: 'att-a',
      status: EventParticipationStatus.maybe,
    );
    await a.cacheEvent(
      testSnapshot('e-1', attendance: mine),
      source: EventAccessSource.attending,
    );
    expect(
      (await a.watchAttendingEventListItems().first).single.attendance,
      mine,
    );

    await cache('e-1');
    expect(
      (await a.watchAttendingEventListItems().first).single.attendance,
      isNull,
    );

    await cache('e-9', attendance: mine);
    expect(
      [
        for (final i in await a.watchAttendingEventListItems().first)
          i.event.id,
      ],
      ['e-1'],
    );
  });

  test(
    "a household item carries the answer kept on the user's attending row",
    () async {
      const mine = EventAttendance(
        attendeeId: 'att-a',
        status: EventParticipationStatus.maybe,
      );
      await a.cacheEvent(
        testSnapshot('e-1', attendance: mine),
        source: EventAccessSource.attending,
      );
      await cache('e-1', attendance: mine);

      final items = await a.watchHouseholdEventListItems('household-1').first;

      expect(items.single.attendance, mine);
    },
  );

  test("with no attending row, a household item falls back to the user's "
      'row on a cached roster', () async {
    await a.cacheEvent(
      testSnapshot('e-1', attendees: [testAttendee('att-a', userId: _kUserA)]),
      source: EventAccessSource.read,
    );
    await cache('e-1');

    final items = await a.watchHouseholdEventListItems('household-1').first;

    expect(items.single.attendance?.attendeeId, 'att-a');
    expect(items.single.attendance?.status, EventParticipationStatus.attending);
  });

  group('with no attending row, the answer is kept on the household row', () {
    const mine = EventAttendance(
      attendeeId: 'att-a',
      status: EventParticipationStatus.maybe,
    );

    Future<EventAttendance?> householdAnswer({
      EventRepositoryImpl? repo,
    }) async =>
        (await (repo ?? a).watchHouseholdEventListItems('household-1').first)
            .single
            .attendance;

    test(
      'and the item carries it, without joining the attending list',
      () async {
        await cache('e-1', attendance: mine);

        expect(await householdAnswer(), mine);
        expect(await a.watchAttendingEventListItems().first, isEmpty);
      },
    );

    test("over the user's row on a cached roster", () async {
      await a.cacheEvent(
        testSnapshot(
          'e-1',
          attendees: [testAttendee('att-a', userId: _kUserA)],
        ),
        source: EventAccessSource.read,
      );
      await cache('e-1', attendance: mine);

      expect(await householdAnswer(), mine);
    });

    test('and a later list write of null clears it', () async {
      await cache('e-1', attendance: mine);
      await cache('e-1');

      expect(await householdAnswer(), isNull);
    });

    test("a detail read's answer replaces it, null included", () async {
      await cache('e-1', attendance: mine);
      const going = EventAttendance(
        attendeeId: 'att-a',
        status: EventParticipationStatus.attending,
      );

      await a.cacheEvent(
        testSnapshot('e-1', attendance: going),
        source: EventAccessSource.read,
      );
      expect(await householdAnswer(), going);

      await a.cacheEvent(testSnapshot('e-1'), source: EventAccessSource.read);
      expect(await householdAnswer(), isNull);
    });

    test("the attending list's answer replaces it, null included", () async {
      await cache('e-1', attendance: mine);
      const notGoing = EventAttendance(
        attendeeId: 'att-a',
        status: EventParticipationStatus.notAttending,
      );

      await a.cacheEvent(
        testSnapshot('e-1', attendance: notGoing),
        source: EventAccessSource.attending,
      );
      expect(await householdAnswer(), notGoing);

      // The `attending` row's null is read past, so this shows only if the
      // household row was cleared too.
      await a.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.attending,
      );
      expect(await householdAnswer(), isNull);
    });

    test("an RSVP's answer replaces it", () async {
      await cache('e-1', attendance: mine);
      final rsvp = testAttendee(
        'att-a',
        userId: _kUserA,
      ).copyWith(status: EventParticipationStatus.notAttending);

      expect(await a.cacheAttendee(rsvp), isTrue);

      expect(await householdAnswer(), EventAttendance.fromAttendee(rsvp));
    });

    test("a roster's row replaces another user's", () async {
      final b = repoFor(_kUserB);
      await cache(
        'e-1',
        repo: b,
        attendance: const EventAttendance(
          attendeeId: 'att-b',
          status: EventParticipationStatus.maybe,
        ),
      );
      final rostered = testAttendee('att-b', userId: _kUserB);

      await a.cacheEvent(
        testSnapshot('e-1', attendees: [rostered]),
        source: EventAccessSource.read,
      );

      expect(
        await householdAnswer(repo: b),
        EventAttendance.fromAttendee(rostered),
      );
    });

    test('the attendance purge clears it, and keeps the row', () async {
      await a.cacheEvent(
        testSnapshot('e-1', attendance: mine),
        source: EventAccessSource.attending,
      );
      await cache('e-1', attendance: mine);
      final p = await a.purgeableAttendance();

      expect(await a.purgeAttendanceAbsentFrom(const {}, purgeable: p), {
        'e-1',
      });

      expect(await listed('household-1'), ['e-1']);
      expect(await householdAnswer(), isNull);
    });
  });

  test('the purge removes absent rows of this household only', () async {
    await cache('e-1');
    await cache('e-2');
    await cache('e-3', householdId: 'household-2');

    expect(await purge('household-1', {'e-1'}), {'e-2'});
    expect(await listed('household-1'), ['e-1']);
    expect(await listed('household-2'), ['e-3']);
  });

  test('the purge keeps an event written since the purgeable read', () async {
    await cache('e-1');
    await cache('e-2');
    final p = await a.purgeableHouseholdEvents('household-1');
    await cache('e-2');

    final purged = await a.purgeHouseholdEventsAbsentFrom(
      'household-1',
      const {},
      purgeable: p,
    );

    expect(purged, {'e-1'});
    expect(await listed('household-1'), ['e-2']);
  });

  test('the purge keeps a dirty event', () async {
    await cache('e-2');
    await markDirty('e-2');

    expect(await a.purgeableHouseholdEvents('household-1'), isEmpty);
    expect(await purge('household-1', const {}), isEmpty);
    expect(await listed('household-1'), ['e-2']);
  });

  test("the purge keeps other access and other users' rows", () async {
    final b = repoFor(_kUserB);
    final attendee = testAttendee('att-a', userId: _kUserA, eventId: 'e-2');
    await a.cacheEvent(
      testSnapshot('e-2', attendees: [attendee]),
      source: EventAccessSource.attending,
    );
    await cache('e-2');
    await cache('e-2', repo: b);
    final before = await a.getCurrentUserAttendance('e-2');
    expect(before, isNotNull);

    expect(await purge('household-1', const {}), {'e-2'});

    expect(
      [
        for (final i in await a.watchAttendingEventListItems().first)
          i.event.id,
      ],
      ['e-2'],
    );
    expect(await listed('household-1', repo: b), ['e-2']);
    expect(await a.getCurrentUserAttendance('e-2'), before);
  });

  test('an event goes with its last access row', () async {
    await cache('e-1');
    await cache('e-2');

    await purge('household-1', {'e-1'});

    final ids = [for (final e in await db.select(db.eventsTable).get()) e.id];
    expect(ids, ['e-1']);
  });

  test(
    'a household row re-emits the watch when its occurrences change',
    () async {
      await cache('e-1');
      final emissions = a
          .watchHouseholdEventListItems('household-1')
          .take(2)
          .toList();
      await pumpEventQueue();

      await cache(
        'e-1',
        occurrences: [testOccurrence('e-1-o2', eventId: 'e-1')],
      );

      final items = await emissions.timeout(const Duration(seconds: 5));
      expect([for (final o in items.last.single.occurrences) o.id], ['e-1-o2']);
    },
  );
}
