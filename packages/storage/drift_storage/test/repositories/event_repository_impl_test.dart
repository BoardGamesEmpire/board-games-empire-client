import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/event_repository_impl.dart';
import 'package:drift_storage/src/tables/event_access_table.dart';

import '../support/event_fixture.dart';

// What one user's cache of an event holds after each kind of read (#496):
// the event and its policy upserted, its occurrences replaced wholesale, its
// roster replaced only by a read that carried one, and every value read back
// as the server sent it, in the server's order. Who may read what is
// event_repository_access_test.dart; the purge is
// event_repository_purge_test.dart.

const _kUserId = 'user-me';
const _kOtherUserId = 'user-other';

// Every roster a test reads back through getEvent holds the current user:
// the cache serves a roster only to a user on it.
final _me = testAttendee('att-me', userId: _kUserId);
final _other = testAttendee('att-other', userId: _kOtherUserId);

void main() {
  late ServerDatabase db;
  late EventRepositoryImpl repo;

  setUp(() {
    db = inMemoryServerDatabase();
    repo = EventRepositoryImpl(db, userId: _kUserId);
  });

  tearDown(() => db.close());

  test('caches an event with its occurrences and policy', () async {
    final snapshot = testSnapshot(
      'e-1',
      occurrences: [testOccurrence('o-1'), testOccurrence('o-2', sortOrder: 1)],
      policy: testPolicy(),
      attendees: [_me, _other],
    );

    await repo.cacheEvent(snapshot, source: EventAccessSource.attending);

    expect(await repo.getEvent('e-1'), snapshot);
  });

  test('an event cached from the list reads back as cached, with no '
      'roster', () async {
    // The list carries no roster, and no detail read has cached one, so the
    // roster is not known: null, as the snapshot had it, rather than the
    // empty list that says this user may not read it.
    final snapshot = testSnapshot('e-1', policy: testPolicy());

    await repo.cacheEvent(snapshot, source: EventAccessSource.attending);

    final cached = await repo.getEvent('e-1');
    expect(cached, snapshot);
    expect(cached!.attendees, isNull);
  });

  test("reads occurrences and the roster in the server's order", () async {
    // The detail read's order: occurrences by sortOrder then id, attendees
    // by createdAt then id, whatever order they arrive in. `att-1` and
    // `att-2` share a millisecond, and as ISO-8601 text the later stamp is
    // written `…00.123001Z`, which sorts first as text (#441). Compared as
    // instants, to the millisecond, the two tie and the ids decide.
    final t = kFixtureEventInstant;
    final mine = testAttendee('att-1', userId: _kUserId, createdAt: t);
    final sameMillisecond = testAttendee(
      'att-2',
      userId: _kOtherUserId,
      createdAt: t.add(const Duration(microseconds: 1)),
    );
    final later = testAttendee(
      'att-0',
      userId: 'user-third',
      createdAt: t.add(const Duration(milliseconds: 1)),
    );
    await repo.cacheEvent(
      testSnapshot(
        'e-1',
        occurrences: [
          testOccurrence('o-c', sortOrder: 1),
          testOccurrence('o-b'),
          testOccurrence('o-a', sortOrder: 1),
        ],
        attendees: [later, sameMillisecond, mine],
      ),
      source: EventAccessSource.read,
    );

    final cached = await repo.getEvent('e-1');

    expect(cached!.occurrences.map((o) => o.id), ['o-b', 'o-a', 'o-c']);
    expect(cached.attendees!.map((a) => a.id), ['att-1', 'att-2', 'att-0']);
  });

  test('replaces occurrences wholesale', () async {
    await repo.cacheEvent(
      testSnapshot(
        'e-1',
        occurrences: [
          testOccurrence('o-1'),
          testOccurrence('o-2', sortOrder: 1),
        ],
      ),
      source: EventAccessSource.attending,
    );

    await repo.cacheEvent(
      testSnapshot('e-1', occurrences: [testOccurrence('o-3')]),
      source: EventAccessSource.attending,
    );

    final replaced = await repo.getEvent('e-1');
    expect(replaced!.occurrences, hasLength(1));
    expect(replaced.occurrences.single.id, 'o-3');

    // The server hard-deletes an occurrence, so an empty list means no dates
    // at all, unlike an empty roster.
    await repo.cacheEvent(
      testSnapshot('e-1', occurrences: const []),
      source: EventAccessSource.attending,
    );

    expect((await repo.getEvent('e-1'))!.occurrences, isEmpty);
  });

  test('a listed snapshot leaves the roster alone', () async {
    await repo.cacheEvent(
      testSnapshot('e-1', attendees: [_me, _other]),
      source: EventAccessSource.read,
    );

    // The list carries no roster, so it says nothing about who is on one.
    await repo.cacheEvent(
      testSnapshot('e-1'),
      source: EventAccessSource.attending,
    );

    final roster = (await repo.getEvent('e-1'))!.attendees;
    expect(roster, hasLength(2));
    expect(roster, [_me, _other]);
  });

  test('an empty roster leaves the roster alone', () async {
    await repo.cacheEvent(
      testSnapshot('e-1', attendees: [_me, _other]),
      source: EventAccessSource.read,
    );

    // An attendee always sees themselves, so an empty roster is one the
    // caller may not read, never an event nobody is coming to.
    await repo.cacheEvent(
      testSnapshot('e-1', attendees: const []),
      source: EventAccessSource.read,
    );

    final roster = (await repo.getEvent('e-1'))!.attendees;
    expect(roster, hasLength(2));
    expect(roster, [_me, _other]);
  });

  test('a non-empty roster replaces the cached one', () async {
    await repo.cacheEvent(
      testSnapshot('e-1', attendees: [_me, _other]),
      source: EventAccessSource.read,
    );

    await repo.cacheEvent(
      testSnapshot('e-1', attendees: [_me]),
      source: EventAccessSource.read,
    );

    final roster = (await repo.getEvent('e-1'))!.attendees;
    expect(roster, hasLength(1));
    expect(roster, [_me]);
  });

  test(
    'getCurrentUserAttendance finds the current user in the roster',
    () async {
      await repo.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.attending,
      );
      expect(
        await repo.getCurrentUserAttendance('e-1'),
        isNull,
        reason: 'the list carries no roster, so no detail read has run yet',
      );

      final mine = _me.copyWith(
        role: EventRole.coHost,
        status: EventParticipationStatus.maybe,
      );
      await repo.cacheEvent(
        testSnapshot('e-1', attendees: [mine, _other]),
        source: EventAccessSource.read,
      );

      final attendance = await repo.getCurrentUserAttendance('e-1');
      expect(attendance?.role, EventRole.coHost);
      expect(attendance?.status, EventParticipationStatus.maybe);
      expect(attendance, mine);
    },
  );

  test('a guest and an undated occurrence round-trip', () async {
    final undated = testOccurrence('o-1')
        .copyWith(startDate: null, endDate: null);
    final guest = testGuest('att-guest');
    final snapshot = testSnapshot(
      'e-1',
      occurrences: [undated],
      attendees: [guest, _me],
    );

    await repo.cacheEvent(snapshot, source: EventAccessSource.read);

    final cached = await repo.getEvent('e-1');
    expect(cached, snapshot);
    expect(cached!.occurrences.single.startDate, isNull);
    expect(cached.attendees!.first.isGuest, isTrue);
    expect(cached.attendees!.first.guestName, 'Grandma');
  });

  test('unknown enum values round-trip', () async {
    // What a newer server sends that this client has no name for: a status
    // backend#795 adds, a role a deployment defines. Every enum column, so
    // none of them can fail the write by asking `unknown` for a wire name.
    final snapshot = EventSnapshot(
      event: testEvent('e-1').copyWith(
        type: EventType.unknown,
        reach: Reach.unknown,
        status: EventStatus.unknown,
        schedulingMode: EventSchedulingMode.unknown,
      ),
      occurrences: [
        testOccurrence('o-1').copyWith(status: OccurrenceStatus.unknown),
      ],
      policy: testPolicy().copyWith(
        gameAdditionMode: GameAdditionMode.unknown,
        voteThresholdType: VoteThresholdType.unknown,
        voteQuorumType: VoteQuorumType.unknown,
        voteEligibility: VoteEligibility.unknown,
        interestedWeight: InterestedWeight.unknown,
      ),
      attendees: [
        _me.copyWith(
          status: EventParticipationStatus.unknown,
          role: EventRole.unknown,
        ),
        _other.copyWith(role: null),
      ],
    );

    await repo.cacheEvent(snapshot, source: EventAccessSource.attending);

    final cached = await repo.getEvent('e-1');
    expect(cached, snapshot);
    expect(cached!.event.status, EventStatus.unknown);
    expect(cached.attendees!.first.role, EventRole.unknown);
    expect(
      cached.attendees!.last.role,
      isNull,
      reason: 'no role binding stays no role',
    );

    // Stored as 'Unknown', which is no enum's wire name.
    final eventRow = await db.select(db.eventsTable).getSingle();
    expect(eventRow.status, 'Unknown');
    final roleNames = {
      for (final row in await db.select(db.eventAttendeesTable).get())
        row.id: row.roleName,
    };
    expect(roleNames, {'att-me': 'Unknown', 'att-other': null});
  });

  test('watchAttendingEvents lists attending events newest created first, and '
      'not read-only ones', () async {
    final t = kFixtureEventInstant;
    await repo.cacheEvent(
      testSnapshot('e-old', createdAt: t),
      source: EventAccessSource.attending,
    );
    await repo.cacheEvent(
      testSnapshot('e-new', createdAt: t.add(const Duration(milliseconds: 1))),
      source: EventAccessSource.attending,
    );
    await repo.cacheEvent(
      testSnapshot('e-read', createdAt: t.add(const Duration(milliseconds: 2))),
      source: EventAccessSource.read,
    );

    final listed = await repo.watchAttendingEvents().first;

    expect(listed.map((e) => e.id), ['e-new', 'e-old']);
    expect(
      listed.first,
      testEvent('e-new', createdAt: t.add(const Duration(milliseconds: 1))),
    );
  });

  test('watchAttendingEvents breaks a tie within one millisecond by id, '
      'highest first (#441)', () async {
    // The list's order is createdAt desc, id desc. As ISO-8601 text `e-a`'s
    // stamp is written `…00.123Z` and the later `e-b`'s `…00.123001Z`, so a
    // descending text sort puts `e-a` first. Compared as instants, to the
    // millisecond, the two tie and the higher id goes first, as on the
    // server.
    final t = kFixtureEventInstant;
    await repo.cacheEvent(
      testSnapshot('e-a', createdAt: t),
      source: EventAccessSource.attending,
    );
    await repo.cacheEvent(
      testSnapshot('e-b', createdAt: t.add(const Duration(microseconds: 1))),
      source: EventAccessSource.attending,
    );

    final listed = await repo.watchAttendingEvents().first;

    expect(listed.map((e) => e.id), ['e-b', 'e-a']);
  });

  test('a snapshot without a policy leaves the cached policy alone', () async {
    await repo.cacheEvent(
      testSnapshot('e-1', policy: testPolicy()),
      source: EventAccessSource.read,
    );

    // The detail read serves no policy to a caller who may not read it, and
    // the server has no policy delete, so null is never news of one.
    await repo.cacheEvent(testSnapshot('e-1'), source: EventAccessSource.read);

    expect((await repo.getEvent('e-1'))!.policy, testPolicy());
  });

  test('a later policy replaces the cached one', () async {
    await repo.cacheEvent(
      testSnapshot('e-1', policy: testPolicy()),
      source: EventAccessSource.read,
    );
    final changed = testPolicy(id: 'pol-2')
        .copyWith(maxAttendees: 10, allowGuestInvites: true);

    await repo.cacheEvent(
      testSnapshot('e-1', policy: changed),
      source: EventAccessSource.read,
    );

    expect((await repo.getEvent('e-1'))!.policy, changed);
    expect(
      await db.select(db.eventPoliciesTable).get(),
      hasLength(1),
      reason: 'an event has at most one policy',
    );
  });

  test('a server write keeps the sync flags a local writer set', () async {
    await repo.cacheEvent(
      testSnapshot('e-1'),
      source: EventAccessSource.attending,
    );
    // No writer sets either flag yet (#499, #527), so set them as one would.
    await (db.update(db.eventsTable)..where((t) => t.id.equals('e-1'))).write(
      const EventsTableCompanion(
        isDirty: Value(true),
        isLocalOnly: Value(true),
      ),
    );

    await repo.cacheEvent(
      testSnapshot('e-1', title: 'Renamed on the server'),
      source: EventAccessSource.attending,
    );

    final cached = (await repo.getEvent('e-1'))!.event;
    expect(cached.title, 'Renamed on the server', reason: 'the write landed');
    expect(cached.isDirty, isTrue);
    expect(cached.isLocalOnly, isTrue);
  });

  group('a page of snapshots', () {
    test('is one write: a live watch emits once', () async {
      // The hydrate writes up to a hundred events a page. Written a
      // transaction per event, a list watching the cache would rebuild once
      // per event on every pass, and show the page half written in between.
      final page = [
        for (var n = 0; n < 100; n++)
          testSnapshot(
            'e-$n',
            createdAt: kFixtureEventInstant.add(Duration(minutes: n)),
          ),
      ];
      final listed = <int>[];
      final watching = repo.watchAttendingEvents().listen(
        (events) => listed.add(events.length),
      );
      addTearDown(watching.cancel);
      await pumpEventQueue();

      await repo.cacheEvents(page, source: EventAccessSource.attending);
      await pumpEventQueue();

      expect(listed, [0, 100]);
    });

    test('writes each snapshot as cacheEvent writes it', () async {
      // The same rules as one read: occurrences replaced wholesale, the
      // roster only by one with someone on it, the policy only by a snapshot
      // carrying one, and access added beside what the user already has.
      final mineOnTwo = testAttendee(
        'att-me-2',
        userId: _kUserId,
        eventId: 'e-2',
      );
      await repo.cacheEvent(
        testSnapshot(
          'e-1',
          occurrences: [
            testOccurrence('o-1'),
            testOccurrence('o-2', sortOrder: 1),
          ],
          policy: testPolicy(),
          attendees: [_me, _other],
        ),
        source: EventAccessSource.read,
      );
      await repo.cacheEvent(
        testSnapshot('e-2', attendees: [mineOnTwo]),
        source: EventAccessSource.read,
      );
      final three = testSnapshot(
        'e-3',
        policy: testPolicy(id: 'pol-3', eventId: 'e-3'),
        attendees: [testAttendee('att-me-3', userId: _kUserId, eventId: 'e-3')],
      );

      await repo.cacheEvents([
        // As the list sends it: no roster, and here no policy.
        testSnapshot('e-1', occurrences: [testOccurrence('o-3')]),
        // A roster this user may not read, and no dates left.
        testSnapshot('e-2', occurrences: const [], attendees: const []),
        three,
      ], source: EventAccessSource.attending);

      final one = (await repo.getEvent('e-1'))!;
      expect(one.occurrences.map((o) => o.id), ['o-3']);
      expect(one.attendees, [_me, _other]);
      expect(one.policy, testPolicy());
      final two = (await repo.getEvent('e-2'))!;
      expect(two.occurrences, isEmpty);
      expect(two.attendees, [mineOnTwo]);
      expect(await repo.getEvent('e-3'), three);
      final access = {
        for (final row in await db.select(db.eventAccessTable).get())
          (row.userId, row.eventId, row.source),
      };
      expect(access, {
        (_kUserId, 'e-1', eventAccessSourceRead),
        (_kUserId, 'e-1', eventAccessSourceAttending),
        (_kUserId, 'e-2', eventAccessSourceRead),
        (_kUserId, 'e-2', eventAccessSourceAttending),
        (_kUserId, 'e-3', eventAccessSourceAttending),
      });
    });
  });
}
