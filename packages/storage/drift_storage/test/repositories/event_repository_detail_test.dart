import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/event_repository_impl.dart';

import '../support/event_fixture.dart';

// The detail screen's storage (#498): one event watched with the current
// user's own row on its roster, and one the server no longer serves
// forgotten for this user alone.

const _kUserA = 'user-a';
const _kUserB = 'user-b';

void main() {
  late ServerDatabase db;
  late EventRepositoryImpl a;
  late EventRepositoryImpl b;

  setUp(() {
    db = inMemoryServerDatabase();
    a = EventRepositoryImpl(db, userId: _kUserA);
    b = EventRepositoryImpl(db, userId: _kUserB);
  });

  tearDown(() => db.close());

  // No writer sets either sync flag yet (#499, #527), so these set them as
  // one would. The cache ignores a snapshot's own flags.
  Future<void> markDirty(String id) =>
      (db.update(db.eventsTable)..where((t) => t.id.equals(id))).write(
        const EventsTableCompanion(isDirty: Value(true)),
      );

  Future<void> markLocalOnly(String id) =>
      (db.update(db.eventsTable)..where((t) => t.id.equals(id))).write(
        const EventsTableCompanion(isLocalOnly: Value(true)),
      );

  // A forget whose read saw the cache as it is now, so nothing has written
  // the event since.
  Future<bool> forget(EventRepositoryImpl repo, String id) async =>
      repo.forgetEvent(id, lastWrite: await repo.lastWrite(id) ?? 0);

  group('watchEvent', () {
    test("emits null for an event that isn't cached", () async {
      expect(await a.watchEvent('e-1').first, isNull);
    });

    test("emits the snapshot and the user's attendance", () async {
      // Someone else first, so the attendance is this user's row and not
      // merely the roster's first.
      await a.cacheEvent(
        testSnapshot(
          'e-1',
          attendees: [
            testAttendee(
              'att-x',
              userId: 'user-x',
              createdAt: DateTime.utc(2020),
            ),
            testAttendee('att-a', userId: _kUserA),
          ],
        ),
        source: EventAccessSource.read,
      );

      final detail = (await a.watchEvent('e-1').first)!;

      expect(detail.snapshot.event, testEvent('e-1'));
      expect(detail.snapshot.attendees!.map((a) => a.id), ['att-x', 'att-a']);
      expect(detail.attendance!.id, 'att-a');
      expect(detail.attendance, await a.getCurrentUserAttendance('e-1'));
    });

    test("keeps the roster's three states", () async {
      // Not asked: the list carries no roster.
      await a.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.attending,
      );
      var detail = (await a.watchEvent('e-1').first)!;
      expect(detail.snapshot.attendees, isNull);
      expect(detail.attendance, isNull);

      // May not read: a roster is cached, and it doesn't name this user.
      // An empty roster over none cached leaves none, which is the first
      // state again, so the roster has to exist and name someone else.
      await a.cacheEvent(
        testSnapshot(
          'e-1',
          attendees: [
            testAttendee('att-a', userId: _kUserA),
            testAttendee('att-x', userId: 'user-x'),
          ],
        ),
        source: EventAccessSource.read,
      );
      await a.cacheEvent(
        testSnapshot('e-1', attendees: const []),
        source: EventAccessSource.read,
      );
      detail = (await a.watchEvent('e-1').first)!;
      expect(detail.snapshot.attendees, isNotNull);
      expect(detail.snapshot.attendees, isEmpty);
      expect(detail.attendance, isNull);

      // May read: the roster names this user.
      final att = testAttendee('att-a', userId: _kUserA);
      await a.cacheEvent(
        testSnapshot('e-1', attendees: [att]),
        source: EventAccessSource.read,
      );
      detail = (await a.watchEvent('e-1').first)!;
      expect(detail.snapshot.attendees, [att]);
      expect(detail.attendance, att);
    });

    test('re-emits when the roster changes', () async {
      await a.cacheEvent(
        testSnapshot(
          'e-1',
          attendees: [testAttendee('att-a', userId: _kUserA)],
        ),
        source: EventAccessSource.read,
      );
      final emissions = a.watchEvent('e-1').take(2).toList();
      await pumpEventQueue();

      await a.cacheEvent(
        testSnapshot(
          'e-1',
          attendees: [
            testAttendee('att-a', userId: _kUserA),
            testAttendee('att-b', userId: _kUserB),
          ],
        ),
        source: EventAccessSource.read,
      );

      final seen = await emissions.timeout(const Duration(seconds: 5));
      expect(seen.map((d) => d!.snapshot.attendees!.length), [1, 2]);
    });

    test("re-emits when the user's access is removed", () async {
      await a.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.attending,
      );
      final emissions = a.watchEvent('e-1').take(2).toList();
      await pumpEventQueue();

      await forget(a, 'e-1');

      final seen = await emissions.timeout(const Duration(seconds: 5));
      expect(seen.map((d) => d == null), [false, true]);
    });

    test('drops consecutive equal emissions', () async {
      final att = testAttendee('att-a', userId: _kUserA);
      await a.cacheEvent(
        testSnapshot('e-1', attendees: [att]),
        source: EventAccessSource.attending,
      );
      final emissions = a.watchEvent('e-1').take(2).toList();
      await pumpEventQueue();

      // The same read again writes every table but changes nothing the
      // detail shows, so it must not reach the subscriber. The real change
      // after it is then the second emission, not the third.
      await a.cacheEvent(
        testSnapshot('e-1', attendees: [att]),
        source: EventAccessSource.attending,
      );
      await pumpEventQueue();
      await a.cacheEvent(
        testSnapshot(
          'e-1',
          attendees: [
            att,
            testAttendee('att-b', userId: _kUserB),
          ],
        ),
        source: EventAccessSource.attending,
      );

      final seen = await emissions.timeout(const Duration(seconds: 5));
      expect(seen.map((d) => d!.snapshot.attendees!.length), [1, 2]);
    });

    test("attendance is never another user's row", () async {
      await b.cacheEvent(
        testSnapshot(
          'e-1',
          attendees: [testAttendee('att-b', userId: _kUserB)],
        ),
        source: EventAccessSource.read,
      );
      await a.cacheEvent(testSnapshot('e-1'), source: EventAccessSource.read);

      final detail = (await a.watchEvent('e-1').first)!;

      expect(detail.attendance, isNull);
      expect(detail.snapshot.attendees, isEmpty);
    });

    test('closes on dispose', () async {
      final done = a.watchEvent('e-1').toList();

      await a.onDispose();

      await expectLater(done, completes);
    });
  });

  group('forgetEvent', () {
    test('removes both sources of access', () async {
      await a.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.attending,
      );
      await a.cacheEvent(testSnapshot('e-1'), source: EventAccessSource.read);

      expect(await forget(a, 'e-1'), isTrue);

      expect(await a.getEvent('e-1'), isNull);
      expect(await a.watchEvent('e-1').first, isNull);
    });

    test('removes an attended event from the attending list', () async {
      await a.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.attending,
      );
      expect(await a.watchAttendingEventListItems().first, hasLength(1));

      await forget(a, 'e-1');

      expect(await a.watchAttendingEventListItems().first, isEmpty);
    });

    test("leaves another user's access and roster row", () async {
      final roster = [
        testAttendee('att-a', userId: _kUserA),
        testAttendee('att-b', userId: _kUserB),
      ];
      for (final repo in [a, b]) {
        await repo.cacheEvent(
          testSnapshot('e-1', attendees: roster),
          source: EventAccessSource.attending,
        );
      }

      expect(await forget(a, 'e-1'), isTrue);

      final rosterForB = (await b.getEvent('e-1'))!.attendees!;
      expect(rosterForB.map((x) => x.id), ['att-b']);
      expect((await b.getCurrentUserAttendance('e-1'))!.id, 'att-b');
      expect(await a.getEvent('e-1'), isNull);
    });

    test('deletes the event and its children with the last access', () async {
      await a.cacheEvent(
        testSnapshot(
          'e-1',
          policy: testPolicy(),
          attendees: [testAttendee('att-a', userId: _kUserA)],
        ),
        source: EventAccessSource.attending,
      );

      expect(await forget(a, 'e-1'), isTrue);

      expect(await db.select(db.eventsTable).get(), isEmpty);
      expect(await db.select(db.eventOccurrencesTable).get(), isEmpty);
      expect(await db.select(db.eventAttendeesTable).get(), isEmpty);
      expect(await db.select(db.eventPoliciesTable).get(), isEmpty);
      expect(await db.select(db.eventAccessTable).get(), isEmpty);
    });

    test('keeps the event while another user can still read it', () async {
      for (final repo in [a, b]) {
        await repo.cacheEvent(
          testSnapshot('e-1', policy: testPolicy()),
          source: EventAccessSource.read,
        );
      }

      expect(await forget(a, 'e-1'), isTrue);

      expect(await db.select(db.eventsTable).get(), hasLength(1));
      expect(await db.select(db.eventOccurrencesTable).get(), hasLength(1));
      expect(await db.select(db.eventPoliciesTable).get(), hasLength(1));
    });

    test('does not forget a local-only event', () async {
      await a.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.attending,
      );
      await markLocalOnly('e-1');

      expect(await forget(a, 'e-1'), isFalse);

      expect(await a.getEvent('e-1'), isNotNull);
    });

    test('does not forget a dirty event', () async {
      await a.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.attending,
      );
      await markDirty('e-1');

      expect(await forget(a, 'e-1'), isFalse);

      expect(await a.getEvent('e-1'), isNotNull);
    });

    test("returns false for an event the user can't read", () async {
      // Cached for B alone: A has no access row, so there is nothing of A's
      // to remove, and B's copy is left whole.
      await b.cacheEvent(testSnapshot('e-1'), source: EventAccessSource.read);

      // B's own mark, so the refusal is A's access and not a stale mark.
      final lastWrite = (await b.lastWrite('e-1'))!;
      expect(await a.forgetEvent('e-1', lastWrite: lastWrite), isFalse);
      expect(
        await a.forgetEvent('e-never-cached', lastWrite: lastWrite),
        isFalse,
      );

      expect(await b.getEvent('e-1'), isNotNull);
    });

    test('throws once the session has ended', () async {
      await a.onDispose();

      expect(() => a.forgetEvent('e-1', lastWrite: 1), throwsStateError);
    });

    test('does not forget an event written since its read was sent', () async {
      await a.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.attending,
      );
      final lastWrite = (await a.lastWrite('e-1'))!;

      // A later open's read, or a hydrate, caches the event while the first
      // read's 404 is still on its way.
      await a.cacheEvent(testSnapshot('e-1'), source: EventAccessSource.read);

      expect(await a.forgetEvent('e-1', lastWrite: lastWrite), isFalse);

      expect(await a.getEvent('e-1'), isNotNull);
      expect(await a.watchAttendingEventListItems().first, hasLength(1));
    });

    test('does not forget an event cached again since it was', () async {
      await a.cacheEvent(testSnapshot('e-1'), source: EventAccessSource.read);
      final lastWrite = (await a.lastWrite('e-1'))!;
      expect(await a.forgetEvent('e-1', lastWrite: lastWrite), isTrue);

      // Deleted, then cached afresh: the new row's mark must not repeat the
      // deleted one's, or a second 404 from the first read's time would
      // pass for it.
      await a.cacheEvent(testSnapshot('e-1'), source: EventAccessSource.read);

      expect(await a.forgetEvent('e-1', lastWrite: lastWrite), isFalse);
      expect(await a.getEvent('e-1'), isNotNull);
    });
  });

  group('lastWrite', () {
    test('moves with every write of the event', () async {
      await a.cacheEvent(testSnapshot('e-1'), source: EventAccessSource.read);
      final first = await a.lastWrite('e-1');

      await b.cacheEvent(testSnapshot('e-1'), source: EventAccessSource.read);

      expect(first, isNotNull);
      expect(await a.lastWrite('e-1'), isNot(first));
    });

    test("is null for an event the user can't read", () async {
      await b.cacheEvent(testSnapshot('e-1'), source: EventAccessSource.read);

      expect(await a.lastWrite('e-1'), isNull);
      expect(await a.lastWrite('e-never-cached'), isNull);
    });

    test('throws once the session has ended', () async {
      await a.onDispose();

      expect(() => a.lastWrite('e-1'), throwsStateError);
    });
  });
}
