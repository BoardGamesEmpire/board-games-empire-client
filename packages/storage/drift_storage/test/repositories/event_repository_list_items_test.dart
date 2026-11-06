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
// dates and the current user's own attendance, from one joined query, so a
// change to any of them reaches the list as one emission. The attendance is
// the list's answer, kept on the user's `attending` access row, else their
// own row on a cached roster (#667).

const _kUserId = 'user-me';
const _kOtherUserId = 'user-other';

final _me = testAttendee('att-me', userId: _kUserId);
final _other = testAttendee('att-other', userId: _kOtherUserId);

final _clock = FixedClockService(DateTime.utc(2026, 10, 26, 12));

/// When the answers below were given: later than the fixture's own RSVP, so
/// a roster row that takes one reads differently from the row it was.
final _answeredAt = DateTime.utc(2026, 10, 20, 9, 30, 0, 456);

/// An answer as a list row carries it: this user's, unless [attendeeId] says
/// otherwise.
EventAttendance _answer(
  EventParticipationStatus status, {
  String attendeeId = 'att-me',
  EventRole? role = EventRole.participant,
}) => EventAttendance(
  attendeeId: attendeeId,
  status: status,
  role: role,
  rsvpDate: _answeredAt,
);

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

  test('a null attendance with no roster shows none', () async {
    // The list row carried no answer and no read has cached a roster, so
    // whether this user said yes is not known.
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

    expect(item.attendance, EventAttendance.fromAttendee(_me));
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
    expect(theirs.attendance, EventAttendance.fromAttendee(_other));
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

  group("the list's attendance (#667)", () {
    /// Caches the event [id] from a list row carrying [attendance], as the
    /// hydrate does, for [as] or this test's user.
    Future<void> listRow(
      String id,
      EventAttendance? attendance, {
      EventRepositoryImpl? as,
    }) => (as ?? repo).cacheEvent(
      testSnapshot(id, attendance: attendance),
      source: EventAccessSource.attending,
    );

    Future<EventListItem> itemOf([EventRepositoryImpl? as]) async =>
        (await (as ?? repo).watchAttendingEventListItems().first).single;

    test("a list row's attendance shows with no roster cached", () async {
      await listRow('e-1', _answer(EventParticipationStatus.maybe));

      final item = await itemOf();

      expect(item.attendance, _answer(EventParticipationStatus.maybe));
      // Not as a row on the roster: one row there would read as a roster of
      // one, and the detail would show it.
      expect((await repo.getEvent('e-1'))!.attendees, isNull);
      expect(await repo.getCurrentUserAttendance('e-1'), isNull);
    });

    test('a later list row replaces the answer', () async {
      await listRow('e-1', _answer(EventParticipationStatus.maybe));
      await listRow(
        'e-1',
        _answer(EventParticipationStatus.notAttending, role: EventRole.coHost),
      );

      expect(
        (await itemOf()).attendance,
        _answer(EventParticipationStatus.notAttending, role: EventRole.coHost),
      );
    });

    test('a page of list rows writes each its own answer', () async {
      // The hydrate's write, over attending rows it wrote before, so every
      // row of the page conflicts and takes its own answer.
      EventAttendance answer(String id, EventParticipationStatus status) =>
          _answer(status, attendeeId: 'att-me-$id');
      Future<void> page(Map<String, EventParticipationStatus> answers) =>
          repo.cacheEvents([
            for (final MapEntry(key: id, value: status) in answers.entries)
              testSnapshot(id, attendance: answer(id, status)),
          ], source: EventAccessSource.attending);
      await page({
        'e-1': EventParticipationStatus.maybe,
        'e-2': EventParticipationStatus.attending,
      });

      await page({
        'e-1': EventParticipationStatus.notAttending,
        'e-2': EventParticipationStatus.maybe,
      });

      final items = await repo.watchAttendingEventListItems().first;
      expect(
        {for (final item in items) item.event.id: item.attendance},
        {
          'e-1': answer('e-1', EventParticipationStatus.notAttending),
          'e-2': answer('e-2', EventParticipationStatus.maybe),
        },
      );
    });

    test('a list row with no attendance clears the answer', () async {
      // Null included: the list row is the newer news.
      await listRow('e-1', _answer(EventParticipationStatus.maybe));
      await listRow('e-1', null);

      expect((await itemOf()).attendance, isNull);
    });

    test("a list row updates the viewer's cached roster row and keeps the "
        'rest', () async {
      final guest = testGuest('att-guest');
      await repo.cacheEvent(
        testSnapshot(
          'e-1',
          attendees: [_me, _other, guest],
          attendance: EventAttendance.fromAttendee(_me),
        ),
        source: EventAccessSource.read,
      );

      await listRow(
        'e-1',
        _answer(EventParticipationStatus.notAttending, role: EventRole.coHost),
      );

      final roster = (await repo.getEvent('e-1'))!.attendees;
      final answered = _me.copyWith(
        status: EventParticipationStatus.notAttending,
        role: EventRole.coHost,
        rsvpDate: _answeredAt,
      );
      // The roster's order: createdAt, then id.
      expect(roster, [guest, answered, _other]);
      expect(await repo.getCurrentUserAttendance('e-1'), answered);
      expect(
        (await itemOf()).attendance!.status,
        EventParticipationStatus.notAttending,
      );
    });

    test("a list row never writes another user's roster row", () async {
      // An attendee id that isn't this user's, which no server sends them.
      await repo.cacheEvent(
        testSnapshot('e-1', attendees: [_me, _other]),
        source: EventAccessSource.read,
      );

      await listRow(
        'e-1',
        _answer(EventParticipationStatus.notAttending, attendeeId: _other.id),
      );

      final otherRepo = repoFor(_kOtherUserId);
      await otherRepo.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.read,
      );
      expect((await otherRepo.getEvent('e-1'))!.attendees, [_me, _other]);
    });

    test("a detail read updates the attending row's answer", () async {
      await listRow('e-1', _answer(EventParticipationStatus.maybe));
      final said = _me.copyWith(rsvpDate: _answeredAt);

      await repo.cacheEvent(
        testSnapshot(
          'e-1',
          attendees: [said, _other],
          attendance: EventAttendance.fromAttendee(said),
        ),
        source: EventAccessSource.read,
      );

      expect((await itemOf()).attendance, EventAttendance.fromAttendee(said));
    });

    test('a detail read with no answer clears the list\'s, and the item '
        'falls back to the roster it read', () async {
      await listRow('e-1', _answer(EventParticipationStatus.maybe));

      // A roster that names the user, read with no answer for them.
      await repo.cacheEvent(
        testSnapshot('e-1', attendees: [_me, _other]),
        source: EventAccessSource.read,
      );

      expect((await itemOf()).attendance, EventAttendance.fromAttendee(_me));
    });

    test('a detail read after the user was removed shows no answer', () async {
      // The server sends no answer for a user who isn't on the event, and a
      // roster without them. Their attending row stays until the next
      // hydrate's purge, but with no answer on it.
      await listRow('e-1', _answer(EventParticipationStatus.attending));

      await repo.cacheEvent(
        testSnapshot('e-1', attendees: [_other]),
        source: EventAccessSource.read,
      );

      expect((await itemOf()).attendance, isNull);
    });

    test("another user's detail read updates this user's answer from the "
        'roster it read', () async {
      // Two users on one device share the cached roster. The other user's
      // read replaces it, this user's row included, so it is the newer news
      // for this user's answer too.
      await listRow('e-1', _answer(EventParticipationStatus.attending));
      final changed = _me.copyWith(
        status: EventParticipationStatus.maybe,
        role: EventRole.coHost,
        rsvpDate: _answeredAt,
      );

      await repoFor(_kOtherUserId).cacheEvent(
        testSnapshot(
          'e-1',
          attendees: [changed, _other],
          attendance: EventAttendance.fromAttendee(_other),
        ),
        source: EventAccessSource.read,
      );

      expect(
        (await itemOf()).attendance,
        EventAttendance.fromAttendee(changed),
      );
      expect(await repo.getCurrentUserAttendance('e-1'), changed);

      // And a list row after it is newer still.
      await listRow('e-1', _answer(EventParticipationStatus.notAttending));
      expect(
        (await itemOf()).attendance,
        _answer(EventParticipationStatus.notAttending),
      );
    });

    test("another user's detail read that leaves this user off keeps their "
        'answer', () async {
      // A roster is read under the reader's own attendee ceiling, so one
      // without this user doesn't say they left.
      await listRow('e-1', _answer(EventParticipationStatus.maybe));

      await repoFor(_kOtherUserId).cacheEvent(
        testSnapshot(
          'e-1',
          attendees: [_other],
          attendance: EventAttendance.fromAttendee(_other),
        ),
        source: EventAccessSource.read,
      );

      expect(
        (await itemOf()).attendance,
        _answer(EventParticipationStatus.maybe),
      );
    });

    test("another user's detail read adds no attending row for this "
        'user', () async {
      // Their roster names this user, but this user's list never had it.
      await repoFor(_kOtherUserId).cacheEvent(
        testSnapshot(
          'e-1',
          attendees: [_me, _other],
          attendance: EventAttendance.fromAttendee(_other),
        ),
        source: EventAccessSource.read,
      );

      expect(await repo.watchAttendingEventListItems().first, isEmpty);
    });

    test('a detail read adds no attending row', () async {
      // The detail speaks for what the user may read, not for their list.
      await repo.cacheEvent(
        testSnapshot(
          'e-1',
          attendees: [_me],
          attendance: EventAttendance.fromAttendee(_me),
        ),
        source: EventAccessSource.read,
      );

      expect(await repo.watchAttendingEventListItems().first, isEmpty);
    });

    test("falls back to the roster row where the list hasn't written "
        'one', () async {
      await listRow('e-1', null);
      await repo.cacheEvent(
        testSnapshot('e-1', attendees: [_me, _other]),
        source: EventAccessSource.read,
      );

      expect((await itemOf()).attendance, EventAttendance.fromAttendee(_me));
    });

    test("the list's answer wins over a roster row it doesn't name", () async {
      // A roster cached before the user left and was invited back names
      // them by their old attendee id. The list is the newer news.
      await repo.cacheEvent(
        testSnapshot('e-1', attendees: [_me, _other]),
        source: EventAccessSource.read,
      );

      await listRow(
        'e-1',
        _answer(EventParticipationStatus.maybe, attendeeId: 'att-me-again'),
      );

      expect(
        (await itemOf()).attendance,
        _answer(EventParticipationStatus.maybe, attendeeId: 'att-me-again'),
      );
      expect(await repo.getCurrentUserAttendance('e-1'), _me);
    });

    test('an unknown status reads back as unknown', () async {
      await listRow(
        'e-1',
        _answer(EventParticipationStatus.unknown, role: EventRole.unknown),
      );

      expect(
        (await itemOf()).attendance,
        _answer(EventParticipationStatus.unknown, role: EventRole.unknown),
      );
    });

    test("another user's attendance never shows", () async {
      final otherRepo = repoFor(_kOtherUserId);
      final theirs = _answer(
        EventParticipationStatus.attending,
        attendeeId: _other.id,
      );
      await listRow('e-1', theirs, as: otherRepo);
      await listRow('e-1', null);

      expect((await itemOf()).attendance, isNull);
      expect((await itemOf(otherRepo)).attendance, theirs);
    });

    test('one item per event, however many access rows and answers it '
        'has', () async {
      // Both users attend and read it, with answers and a roster, so every
      // join has rows for each of them to multiply the occurrences by.
      final otherRepo = repoFor(_kOtherUserId);
      final occurrences = [testOccurrence('o-1'), testOccurrence('o-2')];
      for (final (who, own) in [(repo, _me), (otherRepo, _other)]) {
        await who.cacheEvent(
          testSnapshot(
            'e-1',
            occurrences: occurrences,
            attendees: [_me, _other],
            attendance: EventAttendance.fromAttendee(own),
          ),
          source: EventAccessSource.read,
        );
        await who.cacheEvent(
          testSnapshot(
            'e-1',
            occurrences: occurrences,
            attendance: EventAttendance.fromAttendee(own),
          ),
          source: EventAccessSource.attending,
        );
      }

      final items = await repo.watchAttendingEventListItems().first;

      expect(items, hasLength(1));
      expect(items.single.occurrences.map((o) => o.id), ['o-1', 'o-2']);
      expect(items.single.attendance, EventAttendance.fromAttendee(_me));
    });
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

      expect(emitted.last.single.attendance, EventAttendance.fromAttendee(_me));
    });

    test("when a list row changes this user's answer", () async {
      // Only the `attending` row's answer changes: no roster is cached.
      await repo.cacheEvent(
        testSnapshot(
          'e-1',
          attendance: _answer(EventParticipationStatus.maybe),
        ),
        source: EventAccessSource.attending,
      );
      final emitted = await watch();
      expect(
        emitted.last.single.attendance,
        _answer(EventParticipationStatus.maybe),
      );

      await repo.cacheEvent(
        testSnapshot(
          'e-1',
          attendance: _answer(EventParticipationStatus.attending),
        ),
        source: EventAccessSource.attending,
      );
      await pumpEventQueue();

      expect(
        emitted.last.single.attendance,
        _answer(EventParticipationStatus.attending),
      );
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
