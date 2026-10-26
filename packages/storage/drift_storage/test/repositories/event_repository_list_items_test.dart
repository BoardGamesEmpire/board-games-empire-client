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

// The events overview's one watch (#497): each attending event with its
// dates and the current user's own attendee row, from one joined query, so a
// change to any of the three reaches the list as one emission.

const _kUserId = 'user-me';
const _kOtherUserId = 'user-other';

final _me = testAttendee('att-me', userId: _kUserId);
final _other = testAttendee('att-other', userId: _kOtherUserId);

final _clock = FixedClockService(DateTime.utc(2026, 10, 26, 12));

void main() {
  late ServerDatabase db;
  late EventRepositoryImpl repo;

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
    repo = repoFor(_kUserId);
  });

  tearDown(() => db.close());

  test("emits each attending event with its occurrences in the server's "
      'order', () async {
    // sortOrder first, then id: `o-1` and `o-3` share a sortOrder, and
    // neither the order they arrive in nor the ids alone give this order.
    final o1 = testOccurrence('o-1', sortOrder: 1);
    final o2 = testOccurrence('o-2');
    final o3 = testOccurrence('o-3', sortOrder: 1);
    await repo.cacheEvent(
      testSnapshot('e-1', occurrences: [o3, o2, o1]),
      source: EventAccessSource.attending,
    );

    final item = (await repo.watchAttendingEventListItems().first).single;

    expect(item.event, testEvent('e-1'));
    expect(item.occurrences, [o2, o1, o3]);
  });

  test("keeps the list's order, newest created first", () async {
    // Two occurrences each, so the join returns several rows per event and
    // the fold has to keep them together.
    final t = kFixtureEventInstant;
    for (final (id, minutes) in [('e-old', 0), ('e-new', 2), ('e-mid', 1)]) {
      await repo.cacheEvent(
        testSnapshot(
          id,
          createdAt: t.add(Duration(minutes: minutes)),
          occurrences: [
            testOccurrence('$id-o1', eventId: id),
            testOccurrence('$id-o2', eventId: id, sortOrder: 1),
          ],
        ),
        source: EventAccessSource.attending,
      );
    }

    final items = await repo.watchAttendingEventListItems().first;
    final listed = await repo.watchAttendingEvents().first;

    expect(items.map((i) => i.event.id), ['e-new', 'e-mid', 'e-old']);
    expect(items.map((i) => i.event.id), listed.map((e) => e.id));
    expect(items.map((i) => i.occurrences.length), [2, 2, 2]);
  });

  test('an event with no occurrences has an empty list, not a missing '
      'item', () async {
    // Occurrences are optional on create, so a Fixed event can have no date
    // at all, and an inner join would drop it from the list.
    final t = kFixtureEventInstant;
    await repo.cacheEvent(
      testSnapshot('e-undated', createdAt: t, occurrences: const []),
      source: EventAccessSource.attending,
    );
    await repo.cacheEvent(
      testSnapshot('e-dated', createdAt: t.add(const Duration(minutes: 1))),
      source: EventAccessSource.attending,
    );

    final items = await repo.watchAttendingEventListItems().first;

    expect(items.map((i) => i.event.id), ['e-dated', 'e-undated']);
    expect(items.last.occurrences, isEmpty);
    expect(items.first.occurrences, hasLength(1));
  });

  test('attendance is null when only the list cached the event', () async {
    // The list carries no roster, so whether this user said yes is not known
    // until a detail read (or backend#867).
    await repo.cacheEvent(
      testSnapshot('e-1'),
      source: EventAccessSource.attending,
    );

    final item = (await repo.watchAttendingEventListItems().first).single;

    expect(item.attendance, isNull);
  });

  test('attendance is this user\'s row once a roster names them', () async {
    await repo.cacheEvent(
      testSnapshot(
        'e-1',
        occurrences: [testOccurrence('o-1'), testOccurrence('o-2')],
        attendees: [_me, _other],
      ),
      source: EventAccessSource.attending,
    );

    final item = (await repo.watchAttendingEventListItems().first).single;

    expect(item.attendance, _me);
    // One row per occurrence, not one per occurrence and attendee.
    expect(item.occurrences.map((o) => o.id), ['o-1', 'o-2']);
  });

  test("another user's row on the same roster is not this user's "
      'attendance', () async {
    // Two users on one device share the cached roster. User B's detail read
    // cached a roster naming only B; user A has the event from the list. A
    // must not be handed B's RSVP as their own.
    final otherRepo = repoFor(_kOtherUserId);
    await otherRepo.cacheEvent(
      testSnapshot('e-1', attendees: [_other]),
      source: EventAccessSource.attending,
    );
    await repo.cacheEvent(
      testSnapshot('e-1'),
      source: EventAccessSource.attending,
    );

    final mine = (await repo.watchAttendingEventListItems().first).single;
    final theirs =
        (await otherRepo.watchAttendingEventListItems().first).single;

    expect(mine.attendance, isNull);
    expect(theirs.attendance, _other);
  });

  test('a read-only event is left out', () async {
    // Read by id, not on the user's list.
    await repo.cacheEvent(
      testSnapshot('e-read'),
      source: EventAccessSource.read,
    );
    await repo.cacheEvent(
      testSnapshot('e-mine'),
      source: EventAccessSource.attending,
    );

    final items = await repo.watchAttendingEventListItems().first;

    expect(items.map((i) => i.event.id), ['e-mine']);
  });

  test('another user\'s event is left out', () async {
    final otherRepo = repoFor(_kOtherUserId);
    await otherRepo.cacheEvent(
      testSnapshot('e-theirs'),
      source: EventAccessSource.attending,
    );

    expect(await repo.watchAttendingEventListItems().first, isEmpty);
  });

  group('re-emits', () {
    Future<List<List<EventListItem>>> watch() async {
      final emitted = <List<EventListItem>>[];
      final watching = repo.watchAttendingEventListItems().listen(emitted.add);
      addTearDown(watching.cancel);
      await pumpEventQueue();
      return emitted;
    }

    test('when an occurrence changes', () async {
      await repo.cacheEvent(
        testSnapshot('e-1', occurrences: [testOccurrence('o-1')]),
        source: EventAccessSource.attending,
      );
      final emitted = await watch();

      await repo.cacheEvent(
        testSnapshot(
          'e-1',
          occurrences: [testOccurrence('o-1'), testOccurrence('o-2')],
        ),
        source: EventAccessSource.attending,
      );
      await pumpEventQueue();

      expect(emitted.last.single.occurrences.map((o) => o.id), ['o-1', 'o-2']);
    });

    test("when this user's attendance changes", () async {
      await repo.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.attending,
      );
      final emitted = await watch();
      expect(emitted.last.single.attendance, isNull);

      // A detail read caches the roster, with this user on it.
      await repo.cacheEvent(
        testSnapshot('e-1', attendees: [_me, _other]),
        source: EventAccessSource.read,
      );
      await pumpEventQueue();

      expect(emitted.last.single.attendance, _me);
    });

    test("when a purge removes this user's attendance", () async {
      // Read access keeps the event cached, so only `event_access` changes:
      // the watch has to follow the subquery as well as the joined tables.
      await repo.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.attending,
      );
      await repo.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.read,
      );
      final emitted = await watch();
      expect(emitted.last, hasLength(1));

      await repo.purgeAttendanceAbsentFrom(
        const {},
        purgeable: await repo.purgeableAttendance(),
      );
      await pumpEventQueue();

      expect(emitted.last, isEmpty);
    });
  });

  test('closes once the session scope disposes the repository', () async {
    final done = repo.watchAttendingEventListItems().toList();

    await repo.onDispose();

    await expectLater(done, completes);
  });
}
