import 'package:drift/drift.dart' show Value;
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

// One date written or removed on its own (#506): the cache after a date write
// the server answered, which reads no event.

const _kUser = 'user-a';

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

  Future<void> cache(EventSnapshot snapshot) =>
      repo.cacheEvent(snapshot, source: EventAccessSource.attending);

  Future<void> markLocalOnly(String id) =>
      (db.update(db.eventsTable)..where((t) => t.id.equals(id))).write(
        const EventsTableCompanion(isLocalOnly: Value(true)),
      );

  Future<List<EventOccurrence>> cachedDates(String eventId) async =>
      (await repo.getEvent(eventId))!.occurrences;

  group('cacheOccurrence', () {
    test('replaces the cached date and a watcher sees it', () async {
      await cache(testSnapshot('e1'));
      final emitted = <List<OccurrenceStatus>>[];
      final sub = repo
          .watchEvent('e1')
          .listen(
            (d) => emitted.add([
              for (final o in d!.snapshot.occurrences) o.status,
            ]),
          );
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(emitted.last, [OccurrenceStatus.confirmed]);

      final written = testOccurrence(
        'e1-o1',
        eventId: 'e1',
      ).copyWith(status: OccurrenceStatus.cancelled, cancelReason: 'Rain');
      expect(await repo.cacheOccurrence(written), isTrue);
      await pumpEventQueue();

      expect(emitted.last, [OccurrenceStatus.cancelled]);
      expect(await cachedDates('e1'), [written]);
    });

    test('adds a date not yet cached', () async {
      await cache(testSnapshot('e1'));
      final added = testOccurrence('e1-o2', eventId: 'e1', sortOrder: 1);

      expect(await repo.cacheOccurrence(added), isTrue);

      expect((await cachedDates('e1')).map((o) => o.id), ['e1-o1', 'e1-o2']);
    });

    test('writes nothing for an uncached event', () async {
      final orphan = testOccurrence('o9', eventId: 'gone');

      expect(await repo.cacheOccurrence(orphan), isFalse);

      expect(await db.select(db.eventOccurrencesTable).get(), isEmpty);
    });

    test('leaves a queue-owned event alone', () async {
      await cache(testSnapshot('e1'));
      await markLocalOnly('e1');
      final before = await cachedDates('e1');

      final written = before.single.copyWith(status: OccurrenceStatus.declined);
      expect(await repo.cacheOccurrence(written), isFalse);

      expect(await cachedDates('e1'), before);
    });

    test('moves lastWrite', () async {
      await cache(testSnapshot('e1'));
      final before = await repo.lastWrite('e1');

      await repo.cacheOccurrence(testOccurrence('e1-o1', eventId: 'e1'));

      expect(await repo.lastWrite('e1'), greaterThan(before!));
    });
  });

  group('cacheEventRow', () {
    final cancelledAt = DateTime.utc(2026, 11, 4, 9);

    Event cancelled(Event e) => e.copyWith(
      status: EventStatus.cancelled,
      cancelReason: 'Rain',
      cancelledAt: cancelledAt,
    );

    test(
      'writes the status and cancel fields, and leaves the dates and roster',
      () async {
        await cache(
          testSnapshot(
            'e1',
            occurrences: [
              testOccurrence('o1', eventId: 'e1'),
              testOccurrence('o2', eventId: 'e1', sortOrder: 1),
            ],
            attendees: [testAttendee('a1', userId: _kUser, eventId: 'e1')],
          ),
        );
        final before = (await repo.getEvent('e1'))!;

        expect(await repo.cacheEventRow(cancelled(before.event)), isTrue);

        final after = (await repo.getEvent('e1'))!;
        expect(after.event.status, EventStatus.cancelled);
        expect(after.event.cancelReason, 'Rain');
        expect(after.event.cancelledAt, cancelledAt);
        expect(after.occurrences, before.occurrences);
        expect(after.attendees, before.attendees);
        expect(after.attendees, isNotEmpty);
      },
    );

    test('a reopen clears a cached reason', () async {
      await cache(testSnapshot('e1'));
      final event = (await repo.getEvent('e1'))!.event;
      await repo.cacheEventRow(cancelled(event));

      await repo.cacheEventRow(
        event.copyWith(
          status: EventStatus.planning,
          cancelReason: null,
          cancelledAt: null,
        ),
      );

      final after = (await repo.getEvent('e1'))!.event;
      expect(after.status, EventStatus.planning);
      expect(after.cancelReason, isNull);
      expect(after.cancelledAt, isNull);
    });

    test("returns false for an event that isn't cached", () async {
      expect(await repo.cacheEventRow(testEvent('gone')), isFalse);

      expect(await db.select(db.eventsTable).get(), isEmpty);
    });

    test('returns false and writes nothing for a dirty event', () async {
      await cache(testSnapshot('e1'));
      await (db.update(db.eventsTable)..where((t) => t.id.equals('e1'))).write(
        const EventsTableCompanion(isDirty: Value(true)),
      );
      final before = (await repo.getEvent('e1'))!;

      expect(await repo.cacheEventRow(cancelled(before.event)), isFalse);

      expect((await repo.getEvent('e1'))!.event.status, before.event.status);
    });

    test('returns false and writes nothing for a local-only event', () async {
      await cache(testSnapshot('e1'));
      await markLocalOnly('e1');
      final before = (await repo.getEvent('e1'))!;

      expect(await repo.cacheEventRow(cancelled(before.event)), isFalse);

      expect((await repo.getEvent('e1'))!.event.status, before.event.status);
    });

    test('watchEvent emits once for the write', () async {
      await cache(testSnapshot('e1'));
      final event = (await repo.getEvent('e1'))!.event;
      final emitted = <EventStatus>[];
      final sub = repo
          .watchEvent('e1')
          .listen((d) => emitted.add(d!.snapshot.event.status));
      addTearDown(sub.cancel);
      await pumpEventQueue();
      emitted.clear();
      final before = await repo.lastWrite('e1');

      await repo.cacheEventRow(cancelled(event));
      await pumpEventQueue();

      expect(emitted, [EventStatus.cancelled]);
      expect(await repo.lastWrite('e1'), greaterThan(before!));
    });
  });

  group('removeCachedOccurrence', () {
    test('removes it and keeps the others', () async {
      await cache(
        testSnapshot(
          'e1',
          occurrences: [
            testOccurrence('o1', eventId: 'e1'),
            testOccurrence('o2', eventId: 'e1', sortOrder: 1),
          ],
        ),
      );
      final before = await repo.lastWrite('e1');

      final removed = await repo.removeCachedOccurrence(
        eventId: 'e1',
        occurrenceId: 'o1',
      );

      expect(removed, isTrue);
      expect((await cachedDates('e1')).map((o) => o.id), ['o2']);
      expect(await repo.lastWrite('e1'), greaterThan(before!));
    });

    test('is false for one not cached', () async {
      await cache(testSnapshot('e1'));
      final before = await repo.lastWrite('e1');

      final removed = await repo.removeCachedOccurrence(
        eventId: 'e1',
        occurrenceId: 'nope',
      );

      expect(removed, isFalse);
      expect(await cachedDates('e1'), hasLength(1));
      expect(await repo.lastWrite('e1'), before);
    });

    test('is false for a queue-owned event', () async {
      await cache(testSnapshot('e1'));
      await markLocalOnly('e1');

      final removed = await repo.removeCachedOccurrence(
        eventId: 'e1',
        occurrenceId: 'e1-o1',
      );

      expect(removed, isFalse);
      expect(await cachedDates('e1'), hasLength(1));
    });
  });

  test('a cancel reason round-trips through cacheEvent', () async {
    await cache(testSnapshot('e1'));

    final date = (await cachedDates('e1')).single;

    expect(date.cancelReason, 'Venue flooded');
  });
}
