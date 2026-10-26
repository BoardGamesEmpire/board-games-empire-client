import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/event_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';

import '../support/event_fixture.dart';
import '../support/fixed_clock.dart';

// The hydrate's purge (#496): it removes the current user's attendance of
// the events a snapshot of their list no longer holds, judged only within
// that snapshot's range, and deletes an event once no user can read it.

const _kUserA = 'user-a';
const _kUserB = 'user-b';

final _clock = FixedClockService(DateTime.utc(2026, 10, 26, 12));

void main() {
  late ServerDatabase db;
  late EventRepositoryImpl a;

  /// [userId]'s repository, with a queue of its own over the same database,
  /// as the session scope wires it.
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

  /// Caches the event [id] for A as the hydrate does, from the list.
  Future<void> attend(String id, {DateTime? createdAt}) => a.cacheEvent(
    testSnapshot(id, createdAt: createdAt),
    source: EventAccessSource.attending,
  );

  // Only a create sets the flags yet, and only on an event of its own
  // (#499), so these set them over a cached one, as a queued edit would
  // (#500).
  Future<void> markDirty(String id) =>
      (db.update(db.eventsTable)..where((t) => t.id.equals(id))).write(
        const EventsTableCompanion(isDirty: Value(true)),
      );

  Future<void> markLocalOnly(String id) =>
      (db.update(db.eventsTable)..where((t) => t.id.equals(id))).write(
        const EventsTableCompanion(isLocalOnly: Value(true)),
      );

  test(
    'purgeableAttendance skips local-only and dirty events, and read-only ones',
    () async {
      await attend('e-clean');
      await attend('e-dirty');
      await attend('e-local');
      await a.cacheEvent(
        testSnapshot('e-read'),
        source: EventAccessSource.read,
      );
      await markDirty('e-dirty');
      await markLocalOnly('e-local');

      expect((await a.purgeableAttendance()).keys, {'e-clean'});
    },
  );

  test('a full snapshot removes attending events it does not name', () async {
    await attend('e-kept');
    await attend('e-gone');
    await attend('e-also-gone');
    final purgeable = await a.purgeableAttendance();

    final purged = await a.purgeAttendanceAbsentFrom({
      'e-kept',
    }, purgeable: purgeable);

    expect(purged, {'e-gone', 'e-also-gone'});
    expect(await a.getEvent('e-gone'), isNull);
    expect(await a.getEvent('e-also-gone'), isNull);
    expect(await a.getEvent('e-kept'), isNotNull);
  });

  test('an event still read by this user stays cached after its attending row '
      'goes', () async {
    await attend('e-1');
    await a.cacheEvent(testSnapshot('e-1'), source: EventAccessSource.read);
    final emissions = a.watchAttendingEvents().take(2).toList();
    await pumpEventQueue();

    final purged = await a.purgeAttendanceAbsentFrom(
      const {},
      purgeable: await a.purgeableAttendance(),
    );

    expect(purged, {'e-1'});
    expect(await a.getEvent('e-1'), isNotNull);
    final listed = [
      for (final events in await emissions.timeout(const Duration(seconds: 5)))
        [for (final event in events) event.id],
    ];
    expect(listed, [
      ['e-1'],
      <String>[],
    ]);
  });

  test("removing this user's attendance takes their own row off the cached "
      "roster, and no one else's", () async {
    // The list holds every event this user has an attendee row in that no
    // host has removed, so one it leaves out is one they no longer attend.
    // Kept, their row would still answer with their old role and RSVP, and
    // pass the roster rule, though the server now serves them no roster.
    final b = repoFor(_kUserB);
    final roster = [
      testAttendee('att-a', userId: _kUserA),
      testAttendee('att-b', userId: _kUserB),
      testGuest('att-guest'),
    ];
    await a.cacheEvent(
      testSnapshot('e-1', attendees: roster),
      source: EventAccessSource.read,
    );
    await attend('e-1');
    await b.cacheEvent(
      testSnapshot('e-1'),
      source: EventAccessSource.attending,
    );

    final purged = await a.purgeAttendanceAbsentFrom(
      const {},
      purgeable: await a.purgeableAttendance(),
    );

    expect(purged, {'e-1'});
    expect(await a.getCurrentUserAttendance('e-1'), isNull);
    // A still reads the event by id, and a roster is still cached.
    final rosterForA = (await a.getEvent('e-1'))!.attendees;
    expect(rosterForA, isNotNull, reason: 'a roster is still cached');
    expect(rosterForA, isEmpty, reason: 'and it no longer names A');
    expect(await b.getCurrentUserAttendance('e-1'), roster[1]);
    expect((await b.getEvent('e-1'))!.attendees, [roster[1], roster[2]]);
  });

  test('an event another user still attends stays cached', () async {
    final b = repoFor(_kUserB);
    await attend('e-1');
    await b.cacheEvent(
      testSnapshot('e-1'),
      source: EventAccessSource.attending,
    );

    final purged = await a.purgeAttendanceAbsentFrom(
      const {},
      purgeable: await a.purgeableAttendance(),
    );

    expect(purged, {'e-1'});
    expect(await a.getEvent('e-1'), isNull);
    expect(await b.getEvent('e-1'), isNotNull);
    expect(await b.watchAttendingEvents().first, hasLength(1));
  });

  test(
    'a windowed purge removes only events created after the boundary',
    () async {
      // A first page of a list too long for one page judges only what sorts
      // within it: newest first, down to its last row's createdAt.
      final boundary = kFixtureEventInstant;
      await attend(
        'e-after',
        createdAt: boundary.add(const Duration(milliseconds: 2)),
      );
      await attend(
        'e-named',
        createdAt: boundary.add(const Duration(milliseconds: 1)),
      );
      await attend(
        'e-before',
        createdAt: boundary.subtract(const Duration(milliseconds: 1)),
      );
      final purgeable = await a.purgeableAttendance();

      final purged = await a.purgeAttendanceAbsentFrom(
        {'e-named'},
        purgeable: purgeable,
        newerThan: boundary,
      );

      expect(purged, {'e-after'});
      expect(await a.getEvent('e-after'), isNull);
      expect(await a.getEvent('e-named'), isNotNull);
      expect(
        await a.getEvent('e-before'),
        isNotNull,
        reason: 'it sorts below the first page, so a later page may hold it',
      );
    },
  );

  test('a row tied with the boundary is kept', () async {
    // The first page ends on `e-last`. `e-tied` shares its createdAt to the
    // millisecond, so the server orders the two by id, in a collation SQLite
    // can't reproduce: `e-tied` may be on the next page.
    final boundary = kFixtureEventInstant;
    await attend('e-last', createdAt: boundary);
    await attend('e-tied', createdAt: boundary);
    await attend(
      'e-after',
      createdAt: boundary.add(const Duration(milliseconds: 1)),
    );
    final purgeable = await a.purgeableAttendance();

    final purged = await a.purgeAttendanceAbsentFrom(
      {'e-last'},
      purgeable: purgeable,
      newerThan: boundary,
    );

    expect(purged, {'e-after'}, reason: 'the purge ran');
    expect(await a.getEvent('e-tied'), isNotNull);
  });

  test('an event that became dirty after the purgeable read is kept', () async {
    // A local edit hands it to the queue while the snapshot is in flight.
    await attend('e-1');
    final purgeable = await a.purgeableAttendance();
    await markDirty('e-1');

    final purged = await a.purgeAttendanceAbsentFrom(
      const {},
      purgeable: purgeable,
    );

    expect(purged, isEmpty);
    expect(await a.getEvent('e-1'), isNotNull);
    expect(await a.watchAttendingEvents().first, hasLength(1));
  });

  test('an attending event cached after the purgeable read is kept', () async {
    // Another pass, in another tab, cached it from a list read newer than
    // this pass's, so this pass's snapshot could not have named it.
    final purgeable = await a.purgeableAttendance();
    await attend('e-new');

    final purged = await a.purgeAttendanceAbsentFrom(
      const {},
      purgeable: purgeable,
    );

    expect(purged, isEmpty);
    expect(await a.getEvent('e-new'), isNotNull);
  });

  test(
    'an attending event cached again after the purgeable read is kept',
    () async {
      // This pass's page 1 left it out, but the user was invited back, and
      // another tab's pass cached it again from a newer read of the list
      // before this one's response came back.
      await attend('e-1');
      final purgeable = await a.purgeableAttendance();
      await attend('e-1');

      final purged = await a.purgeAttendanceAbsentFrom(
        const {},
        purgeable: purgeable,
      );

      expect(purged, isEmpty);
      expect(await a.watchAttendingEvents().first, hasLength(1));
    },
  );

  test(
    'an attending event deleted and cached again after the purgeable read is '
    'kept',
    () async {
      // As above, but another tab's pass purged it first, and no one else
      // could read it, so the event went. The row cached after the user was
      // invited back is a new one, written once, as the one this pass read
      // had been.
      await attend('e-1');
      final purgeable = await a.purgeableAttendance();
      await a.purgeAttendanceAbsentFrom(
        const {},
        purgeable: await a.purgeableAttendance(),
      );
      await attend('e-1');

      final purged = await a.purgeAttendanceAbsentFrom(
        const {},
        purgeable: purgeable,
      );

      expect(purged, isEmpty);
      expect(await a.watchAttendingEvents().first, hasLength(1));
    },
  );

  test('an event a detail read wrote after the purgeable read keeps the '
      "user's attendance and roster row", () async {
    final mine = testAttendee('att-a', userId: _kUserA);
    await attend('e-1');
    final purgeable = await a.purgeableAttendance();
    await a.cacheEvent(
      testSnapshot('e-1', attendees: [mine]),
      source: EventAccessSource.read,
    );

    final purged = await a.purgeAttendanceAbsentFrom(
      const {},
      purgeable: purgeable,
    );

    expect(purged, isEmpty);
    expect(await a.getCurrentUserAttendance('e-1'), mine);
    expect(await a.watchAttendingEvents().first, hasLength(1));
  });

  test(
    'removing the last access row deletes the occurrences, roster and policy',
    () async {
      Future<Map<String, int>> rowsOf(String id) async => {
        'events': (await (db.select(
          db.eventsTable,
        )..where((t) => t.id.equals(id))).get()).length,
        'occurrences': (await (db.select(
          db.eventOccurrencesTable,
        )..where((t) => t.eventId.equals(id))).get()).length,
        'attendees': (await (db.select(
          db.eventAttendeesTable,
        )..where((t) => t.eventId.equals(id))).get()).length,
        'policies': (await (db.select(
          db.eventPoliciesTable,
        )..where((t) => t.eventId.equals(id))).get()).length,
        'access': (await (db.select(
          db.eventAccessTable,
        )..where((t) => t.eventId.equals(id))).get()).length,
      };
      for (final id in ['e-gone', 'e-kept']) {
        await a.cacheEvent(
          testSnapshot(
            id,
            occurrences: [
              testOccurrence('$id-o1', eventId: id),
              testOccurrence('$id-o2', eventId: id, sortOrder: 1),
            ],
            policy: testPolicy(id: '$id-policy', eventId: id),
            attendees: [
              testAttendee('$id-a', userId: _kUserA, eventId: id),
              testGuest('$id-guest', eventId: id),
            ],
          ),
          source: EventAccessSource.attending,
        );
      }

      final purged = await a.purgeAttendanceAbsentFrom({
        'e-kept',
      }, purgeable: await a.purgeableAttendance());

      expect(purged, {'e-gone'});
      expect(await rowsOf('e-gone'), {
        'events': 0,
        'occurrences': 0,
        'attendees': 0,
        'policies': 0,
        'access': 0,
      });
      expect(await rowsOf('e-kept'), {
        'events': 1,
        'occurrences': 2,
        'attendees': 2,
        'policies': 1,
        'access': 1,
      });
    },
  );
}
