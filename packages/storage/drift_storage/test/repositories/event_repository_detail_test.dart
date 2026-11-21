import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/event_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../support/event_fixture.dart';
import '../support/fixed_clock.dart';

// The detail screen's storage (#498): one event watched with the current
// user's own row on its roster, and one the server no longer serves
// forgotten for this user alone.

const _kUserA = 'user-a';
const _kUserB = 'user-b';

final _clock = FixedClockService(DateTime.utc(2026, 10, 26, 12));

void main() {
  late ServerDatabase db;
  late EventRepositoryImpl a;
  late EventRepositoryImpl b;

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
    b = repoFor(_kUserB);
  });

  tearDown(() => db.close());

  // Only a create sets the flags yet, and only on an event of its own
  // (#499), so these set them over a cached one, as a queued edit would
  // (#500). The cache ignores a snapshot's own flags.
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

    test("watchEvent emits when a date's rules change", () async {
      await a.cacheEvent(
        testSnapshot(
          'e-1',
          policy: testPolicy(),
          occurrencePolicies: [testOccurrencePolicy('e-1-o1')],
        ),
        source: EventAccessSource.read,
      );
      final emissions = a.watchEvent('e-1').take(2).toList();
      await pumpEventQueue();

      // Every repository write also stamps the event's row, which the watch
      // follows already, so the rules table is written alone here: the watch
      // must follow it on its own.
      await (db.update(
        db.eventOccurrencePoliciesTable,
      )..where((t) => t.occurrenceId.equals('e-1-o1'))).write(
        const EventOccurrencePoliciesTableCompanion(maxAttendees: Value(3)),
      );

      final seen = await emissions.timeout(const Duration(seconds: 5));
      expect(
        seen.map((d) => d!.snapshot.occurrencePolicies!.single.maxAttendees),
        [6, 3],
      );
    });

    test('closes on dispose', () async {
      final done = a.watchEvent('e-1').toList();

      await a.onDispose();

      await expectLater(done, completes);
    });
  });

  group("each date's rules and the policy lists (#1009)", () {
    final dates = [
      testOccurrence('e-1-o1'),
      testOccurrence('e-1-o2', sortOrder: 1),
    ];
    final rules = [
      testOccurrencePolicy('e-1-o1'),
      testOccurrencePolicy('e-1-o2').copyWith(maxAttendees: 4),
    ];

    /// `GET /events/:id` for A: the policy with its lists, and [dateRules].
    Future<void> readDetail({
      EventPolicy? policy,
      List<EventOccurrencePolicy>? dateRules,
    }) => a.cacheEvent(
      testSnapshot(
        'e-1',
        occurrences: dates,
        policy: policy ?? testPolicy(),
        attendees: [testAttendee('att-a', userId: _kUserA)],
        occurrencePolicies: dateRules ?? rules,
      ),
      source: EventAccessSource.read,
    );

    Future<EventPoliciesTableData> policyRow() =>
        db.select(db.eventPoliciesTable).getSingle();

    test(
      "a detail read caches each date's rules and the policy lists",
      () async {
        await readDetail();

        final cached = (await a.getEvent('e-1'))!;
        expect(cached.policy, testPolicy());
        expect(cached.occurrencePolicies, rules);

        // Stored as the table says: JSON arrays, the platform types by their
        // wire names, and the scope by its own.
        final row = await policyRow();
        expect(row.allowedPlatformTypesJson, '["PC","Tabletop"]');
        expect(row.allowedPlatformIdsJson, '["platform-1","platform-2"]');
        expect(row.allowedCategoryIdsJson, '["category-1"]');
        expect(row.occurrenceOverrideScope, 'TightenOnly');
        final ruleRows = await (db.select(
          db.eventOccurrencePoliciesTable,
        )..orderBy([(t) => OrderingTerm.asc(t.occurrenceId)])).get();
        expect(ruleRows.map((r) => (r.occurrenceId, r.eventId)), [
          ('e-1-o1', 'e-1'),
          ('e-1-o2', 'e-1'),
        ]);
        expect(ruleRows.first.allowedPlatformTypesJson, '["Console"]');
        expect(ruleRows.first.gameAdditionMode, 'RequiresVote');
      },
    );

    test(
      'a list read keeps the lists and date rules a detail read cached',
      () async {
        for (final source in [
          EventAccessSource.attending,
          EventAccessSource.household,
        ]) {
          await readDetail();

          // The list rows, as `GET /events` and a household's list serve
          // them: the policy row with none of its lists, and no date rules.
          // Its own columns are newer news, and are written.
          await a.cacheEvents([
            testSnapshot(
              'e-1',
              occurrences: dates,
              policy: listedPolicy(testPolicy()).copyWith(maxAttendees: 10),
            ),
          ], source: source);

          final cached = (await a.getEvent('e-1'))!;
          expect(
            cached.policy,
            testPolicy().copyWith(maxAttendees: 10),
            reason: 'from $source',
          );
          expect(cached.occurrencePolicies, rules, reason: 'from $source');
        }
      },
    );

    test('a list read writes the override scope its row carries', () async {
      // The scope is a column of the policy row, which the lists serve whole
      // (backend `policy: true`), so a list row's scope is the server's own,
      // not a default standing in for one it left out.
      await readDetail();

      await a.cacheEvent(
        testSnapshot(
          'e-1',
          occurrences: dates,
          policy: listedPolicy(
            testPolicy(),
          ).copyWith(occurrenceOverrideScope: OccurrenceOverrideScope.none),
        ),
        source: EventAccessSource.attending,
      );

      final policy = (await a.getEvent('e-1'))!.policy!;
      expect(policy.occurrenceOverrideScope, OccurrenceOverrideScope.none);
      expect(policy.allowedPlatformIds, testPolicy().allowedPlatformIds);
    });

    test(
      "a detail read that drops a date's override removes its row",
      () async {
        await readDetail();

        await readDetail(dateRules: [rules.first]);

        expect((await a.getEvent('e-1'))!.occurrencePolicies, [rules.first]);
        expect(
          await db.select(db.eventOccurrencePoliciesTable).get(),
          hasLength(1),
        );
      },
    );

    test('a detail read with no date rules leaves none', () async {
      await readDetail();

      await readDetail(dateRules: const []);

      expect((await a.getEvent('e-1'))!.occurrencePolicies, isEmpty);
      expect(await db.select(db.eventOccurrencePoliciesTable).get(), isEmpty);
    });

    test('a detail read refused the policy keeps it and the date '
        'rules', () async {
      // A caller who may not read the policy gets `policy: null` and
      // `occurrencePolicies: []`. That empty list is the refusal, not news
      // that no date has rules, so both stay as cached, as for any snapshot
      // without a policy.
      await readDetail();

      await a.cacheEvent(
        testSnapshot(
          'e-1',
          occurrences: dates,
          attendees: [testAttendee('att-a', userId: _kUserA)],
          occurrencePolicies: const [],
        ),
        source: EventAccessSource.read,
      );

      final cached = (await a.getEvent('e-1'))!;
      expect(cached.policy, testPolicy());
      expect(cached.occurrencePolicies, rules);
      expect(
        await db.select(db.eventOccurrencePoliciesTable).get(),
        hasLength(2),
      );
    });

    test('date rules read null until a read carries the lists', () async {
      // Cached from the list alone: neither the lists nor the dates' rules
      // have been read, which is not the same as none.
      await a.cacheEvent(
        testSnapshot(
          'e-1',
          occurrences: dates,
          policy: listedPolicy(testPolicy()),
        ),
        source: EventAccessSource.attending,
      );
      var cached = (await a.getEvent('e-1'))!;
      expect(cached.policy!.allowedPlatformIds, isNull);
      expect(cached.occurrencePolicies, isNull);

      // No policy cached at all.
      await a.cacheEvent(testSnapshot('e-2'), source: EventAccessSource.read);
      expect((await a.getEvent('e-2'))!.occurrencePolicies, isNull);

      await readDetail(dateRules: const []);
      cached = (await a.getEvent('e-1'))!;
      expect(cached.occurrencePolicies, isNotNull);
      expect(cached.occurrencePolicies, isEmpty);
    });

    test(
      "a policy with its lists but no dates' rules leaves them null",
      () async {
        // As a create's answer carries it: the lists, and no dates' rules.
        // Those are still not known, though the lists are.
        await a.cacheEvent(
          testSnapshot('e-1', occurrences: dates, policy: testPolicy()),
          source: EventAccessSource.read,
        );
        var cached = (await a.getEvent('e-1'))!;
        expect(cached.policy!.allowedPlatformIds, isNotNull);
        expect(cached.occurrencePolicies, isNull);
        expect((await policyRow()).occurrencePoliciesRead, isFalse);

        // The detail read sets the flag, and a list read after it, which
        // carries no rules, leaves them known.
        await readDetail();
        expect((await policyRow()).occurrencePoliciesRead, isTrue);
        await a.cacheEvent(
          testSnapshot(
            'e-1',
            occurrences: dates,
            policy: listedPolicy(testPolicy()),
          ),
          source: EventAccessSource.attending,
        );
        cached = (await a.getEvent('e-1'))!;
        expect(cached.occurrencePolicies, rules);
      },
    );

    test("a read that brings a date the detail read didn't serve makes the "
        'date rules not known', () async {
      // A date added since, which may have rules of its own that no read has
      // carried, so "no override" can't be said of it.
      final added = testOccurrence('e-1-o3', sortOrder: 2);
      final reads = <String, Future<void> Function()>{
        'a list read': () => a.cacheEvent(
          testSnapshot(
            'e-1',
            occurrences: [...dates, added],
            policy: listedPolicy(testPolicy()),
          ),
          source: EventAccessSource.attending,
        ),
        'a household list read': () => a.cacheEvents([
          testSnapshot(
            'e-1',
            occurrences: [...dates, added],
            policy: listedPolicy(testPolicy()),
          ),
        ], source: EventAccessSource.household),
        'a detail read refused the policy': () => a.cacheEvent(
          testSnapshot(
            'e-1',
            occurrences: [...dates, added],
            attendees: [testAttendee('att-a', userId: _kUserA)],
            occurrencePolicies: const [],
          ),
          source: EventAccessSource.read,
        ),
        'a date write': () => a.cacheOccurrence(added),
      };
      for (final MapEntry(key: read, value: write) in reads.entries) {
        await readDetail();

        await write();

        expect(
          (await a.getEvent('e-1'))!.occurrencePolicies,
          isNull,
          reason: read,
        );
        // The rows the detail read cached stay, for it to replace.
        expect(
          await db.select(db.eventOccurrencePoliciesTable).get(),
          hasLength(2),
          reason: read,
        );
      }

      // The next detail read covers every date again.
      await readDetail();
      expect((await a.getEvent('e-1'))!.occurrencePolicies, rules);
    });

    test('a read or write that keeps or drops dates leaves the date rules '
        'known', () async {
      await readDetail();

      // A date write over a date the detail read served.
      await a.cacheOccurrence(dates.first.copyWith(label: 'Renamed'));
      expect((await a.getEvent('e-1'))!.occurrencePolicies, rules);

      // A list read that drops a date: the rest stay covered.
      await a.cacheEvent(
        testSnapshot(
          'e-1',
          occurrences: [dates.first],
          policy: listedPolicy(testPolicy()),
        ),
        source: EventAccessSource.attending,
      );
      expect((await a.getEvent('e-1'))!.occurrencePolicies, [rules.first]);
      expect((await policyRow()).occurrencePoliciesRead, isTrue);
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
          occurrencePolicies: [testOccurrencePolicy('e-1-o1')],
        ),
        source: EventAccessSource.attending,
      );
      // So the emptiness below is the delete's, not an unwritten fixture's.
      expect(
        await db.select(db.eventOccurrencePoliciesTable).get(),
        isNotEmpty,
      );

      expect(await forget(a, 'e-1'), isTrue);

      expect(await db.select(db.eventsTable).get(), isEmpty);
      expect(await db.select(db.eventOccurrencesTable).get(), isEmpty);
      expect(await db.select(db.eventAttendeesTable).get(), isEmpty);
      expect(await db.select(db.eventPoliciesTable).get(), isEmpty);
      expect(await db.select(db.eventOccurrencePoliciesTable).get(), isEmpty);
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
      await a.cacheEvent(
        testSnapshot(
          'e-1',
          attendance: EventAttendance.fromAttendee(
            testAttendee('att-a', userId: _kUserA),
          ),
        ),
        source: EventAccessSource.read,
      );

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

  group('removeDeletedEvent', () {
    test('removes the event for every user on the device', () async {
      final roster = [
        testAttendee('att-a', userId: _kUserA),
        testAttendee('att-b', userId: _kUserB),
      ];
      await a.cacheEvent(
        testSnapshot('e-1', policy: testPolicy(), attendees: roster),
        source: EventAccessSource.attending,
      );
      await b.cacheEvent(
        testSnapshot(
          'e-1',
          policy: testPolicy(),
          attendees: roster,
          occurrencePolicies: [testOccurrencePolicy('e-1-o1')],
        ),
        source: EventAccessSource.read,
      );
      // So the emptiness below is the delete's, not an unwritten fixture's.
      expect(
        await db.select(db.eventOccurrencePoliciesTable).get(),
        isNotEmpty,
      );

      expect(await a.removeDeletedEvent('e-1'), isTrue);

      expect(await a.getEvent('e-1'), isNull);
      expect(await b.getEvent('e-1'), isNull);
      expect(await db.select(db.eventsTable).get(), isEmpty);
      expect(await db.select(db.eventAttendeesTable).get(), isEmpty);
      expect(await db.select(db.eventOccurrencesTable).get(), isEmpty);
      expect(await db.select(db.eventPoliciesTable).get(), isEmpty);
      expect(await db.select(db.eventOccurrencePoliciesTable).get(), isEmpty);
      expect(await db.select(db.eventAccessTable).get(), isEmpty);
    });

    test('takes no mark: an event written since is removed too', () async {
      await a.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.attending,
      );
      final lastWrite = (await a.lastWrite('e-1'))!;

      // Written again since, as a hydrate landing mid-request does. The
      // marked forget would decline here, and the delete is already
      // accepted.
      await a.cacheEvent(testSnapshot('e-1'), source: EventAccessSource.read);
      expect(await a.lastWrite('e-1'), isNot(lastWrite));

      expect(await a.removeDeletedEvent('e-1'), isTrue);

      expect(await a.getEvent('e-1'), isNull);
    });

    test('the watch and the attending list see it go', () async {
      await a.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.attending,
      );
      final detail = a.watchEvent('e-1').take(2).toList();
      final list = a.watchAttendingEventListItems().take(2).toList();
      await pumpEventQueue();

      await a.removeDeletedEvent('e-1');

      final seenDetail = await detail.timeout(const Duration(seconds: 5));
      expect(seenDetail.map((d) => d == null), [false, true]);
      final seenList = await list.timeout(const Duration(seconds: 5));
      expect(seenList.map((l) => l.length), [1, 0]);
    });

    test('leaves an event the sync queue owns', () async {
      await a.cacheEvent(
        testSnapshot('e-1'),
        source: EventAccessSource.attending,
      );
      await markDirty('e-1');
      expect(await a.removeDeletedEvent('e-1'), isFalse);
      expect(await a.getEvent('e-1'), isNotNull);

      await a.cacheEvent(
        testSnapshot('e-2'),
        source: EventAccessSource.attending,
      );
      await markLocalOnly('e-2');
      expect(await a.removeDeletedEvent('e-2'), isFalse);
      expect(await a.getEvent('e-2'), isNotNull);
    });

    test('an event never cached answers false', () async {
      expect(await a.removeDeletedEvent('e-never-cached'), isFalse);
    });

    test('throws once the session has ended', () async {
      await a.onDispose();

      expect(() => a.removeDeletedEvent('e-1'), throwsStateError);
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
