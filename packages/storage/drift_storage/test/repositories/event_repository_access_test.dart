import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/event_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';

import '../support/event_fixture.dart';
import '../support/fixed_clock.dart';

const _kUserA = 'user-a';
const _kUserB = 'user-b';

final _clock = FixedClockService(DateTime.utc(2026, 10, 26, 12));

/// The event cache is one set of tables per server, shared by every user
/// signed in to it on this device. Each read returns only the events cached
/// for its own user, and a roster only to a user on it (#496).
void main() {
  late ServerDatabase db;

  setUp(() => db = inMemoryServerDatabase());
  tearDown(() => db.close());

  /// [userId]'s repository, with a queue of its own over the same database,
  /// as the session scope wires it.
  EventRepositoryImpl repoFor(String userId) => EventRepositoryImpl(
    db,
    userId: userId,
    syncQueue: SyncQueueRepositoryImpl(db, _clock, userId: userId),
    clock: _clock,
  );

  test('another user sees nothing of an event cached for this user', () async {
    final a = repoFor(_kUserA);
    final b = repoFor(_kUserB);
    // A's roster names B, who is invited too. The server has sent B nothing
    // on this device yet, so B reads nothing, roster row or not.
    await a.cacheEvent(
      testSnapshot(
        'e-1',
        policy: testPolicy(),
        attendees: [
          testAttendee('att-a', userId: _kUserA),
          testAttendee('att-b', userId: _kUserB),
        ],
      ),
      source: EventAccessSource.attending,
    );

    expect(await b.getEvent('e-1'), isNull);
    expect(await b.getCurrentUserAttendance('e-1'), isNull);
    expect(await b.watchAttendingEvents().first, isEmpty);
    expect(await b.purgeableAttendance(), isEmpty);
    expect(await a.getEvent('e-1'), isNotNull);
  });

  test('a read-only event is readable but not attending', () async {
    final a = repoFor(_kUserA);
    await a.cacheEvent(testSnapshot('e-1'), source: EventAccessSource.read);

    expect(await a.getEvent('e-1'), isNotNull);
    expect(await a.watchAttendingEvents().first, isEmpty);
    expect(await a.purgeableAttendance(), isEmpty);
  });

  test(
    'a user with access who is not on the cached roster reads it as empty',
    () async {
      final a = repoFor(_kUserA);
      final b = repoFor(_kUserB);
      final roster = [
        testAttendee('att-a', userId: _kUserA),
        testGuest('att-guest'),
      ];
      await a.cacheEvent(
        testSnapshot('e-1', attendees: roster),
        source: EventAccessSource.attending,
      );

      // B reads the event as a friend would, and the server serves a friend
      // no roster (backend#560). The cached one holds A's guest, whom B was
      // never shown.
      await b.cacheEvent(
        testSnapshot('e-1', attendees: const []),
        source: EventAccessSource.read,
      );

      final rosterForB = (await b.getEvent('e-1'))!.attendees;
      expect(rosterForB, isNotNull, reason: 'a roster is cached');
      expect(rosterForB, isEmpty, reason: 'and it does not name B');
      expect(await b.getCurrentUserAttendance('e-1'), isNull);
      expect((await a.getEvent('e-1'))!.attendees, roster);
    },
  );

  test('an empty roster for a user who left removes only their row', () async {
    final a = repoFor(_kUserA);
    final b = repoFor(_kUserB);
    final attA = testAttendee('att-a', userId: _kUserA);
    await a.cacheEvent(
      testSnapshot(
        'e-1',
        attendees: [
          attA,
          testAttendee('att-b', userId: _kUserB),
        ],
      ),
      source: EventAccessSource.attending,
    );
    await b.cacheEvent(testSnapshot('e-1'), source: EventAccessSource.read);

    // B leaves, and reads the event again as a friend. The server serves
    // a friend no roster (backend#560), so B's old row must stop showing
    // B A's.
    await b.cacheEvent(
      testSnapshot('e-1', attendees: const []),
      source: EventAccessSource.read,
    );

    expect((await b.getEvent('e-1'))!.attendees, isEmpty);
    expect(await b.getCurrentUserAttendance('e-1'), isNull);
    expect((await a.getEvent('e-1'))!.attendees, [attA]);
    expect(await a.getCurrentUserAttendance('e-1'), attA);
  });

  test('an attendee reads the roster another user cached', () async {
    final a = repoFor(_kUserA);
    final b = repoFor(_kUserB);
    final roster = [
      testAttendee('att-a', userId: _kUserA),
      testAttendee('att-b', userId: _kUserB),
    ];
    await a.cacheEvent(
      testSnapshot('e-1', attendees: roster),
      source: EventAccessSource.read,
    );

    // B's hydrate caches the event from the list, which carries no roster.
    // B is on the one A cached, as the server would show B.
    await b.cacheEvent(
      testSnapshot('e-1'),
      source: EventAccessSource.attending,
    );

    expect((await b.getEvent('e-1'))!.attendees, roster);
    expect(await b.getCurrentUserAttendance('e-1'), roster.last);
  });

  // Each rule matches a user per event, not anywhere in the cache. In these
  // two B has rows of its own, an access row and a place on a roster, so a
  // check that asked only whether B has any row would let B through.

  test("a user on their own event's roster reads no other roster that does "
      'not name them', () async {
    final a = repoFor(_kUserA);
    final b = repoFor(_kUserB);
    final mine = testAttendee('att-b', userId: _kUserB, eventId: 'e-b');
    await b.cacheEvent(
      testSnapshot('e-b', attendees: [mine]),
      source: EventAccessSource.attending,
    );
    await a.cacheEvent(
      testSnapshot(
        'e-a',
        attendees: [
          testAttendee('att-a', userId: _kUserA, eventId: 'e-a'),
          testGuest('att-guest', eventId: 'e-a'),
        ],
      ),
      source: EventAccessSource.attending,
    );

    // B reads A's event as a friend would, and is served no roster.
    await b.cacheEvent(
      testSnapshot('e-a', attendees: const []),
      source: EventAccessSource.read,
    );

    final roster = (await b.getEvent('e-a'))!.attendees;
    expect(roster, isNotNull, reason: 'a roster is cached');
    expect(roster, isEmpty, reason: 'and it does not name B');
    expect(await b.getCurrentUserAttendance('e-a'), isNull);
    expect((await b.getEvent('e-b'))!.attendees, [mine]);
    expect(await b.getCurrentUserAttendance('e-b'), mine);
  });

  test('a user with events of their own reads nothing of one they have no '
      'access to, even on a roster that names them', () async {
    final a = repoFor(_kUserA);
    final b = repoFor(_kUserB);
    await b.cacheEvent(
      testSnapshot(
        'e-b',
        attendees: [testAttendee('att-b', userId: _kUserB, eventId: 'e-b')],
      ),
      source: EventAccessSource.attending,
    );
    // A attends e-a, and A's detail read of it names B, who is invited too.
    // The server has sent B nothing of e-a on this device.
    await a.cacheEvent(
      testSnapshot('e-a'),
      source: EventAccessSource.attending,
    );
    await a.cacheEvent(
      testSnapshot(
        'e-a',
        attendees: [
          testAttendee('att-a', userId: _kUserA, eventId: 'e-a'),
          testAttendee('att-b-on-a', userId: _kUserB, eventId: 'e-a'),
        ],
      ),
      source: EventAccessSource.read,
    );

    expect(await b.getEvent('e-a'), isNull);
    expect(await b.getCurrentUserAttendance('e-a'), isNull);
    expect(
      [for (final event in await b.watchAttendingEvents().first) event.id],
      ['e-b'],
    );
  });
}
