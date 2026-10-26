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

// A server read leaves an event the sync queue owns alone (#499): one that is
// `isLocalOnly`, created here and not yet acknowledged, or `isDirty`, with
// changes not yet sent. Writing the server's copy over either would undo what
// the queue is about to send, or replace a local-only event with one the
// server has not seen. The household rule is the same.

const _kUserId = 'user-me';
const _kOtherUserId = 'user-other';

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

  // Only a create sets the flags yet, and only on an event of its own
  // (#499), so these set them over a cached one, as a queued edit would
  // (#500): the row is cached, then the flag is written over it.
  Future<void> markLocalOnly(String id) =>
      (db.update(db.eventsTable)..where((t) => t.id.equals(id))).write(
        const EventsTableCompanion(isLocalOnly: Value(true)),
      );

  Future<void> markDirty(String id) =>
      (db.update(db.eventsTable)..where((t) => t.id.equals(id))).write(
        const EventsTableCompanion(isDirty: Value(true)),
      );

  Future<void> clearFlags(String id) =>
      (db.update(db.eventsTable)..where((t) => t.id.equals(id))).write(
        const EventsTableCompanion(
          isDirty: Value(false),
          isLocalOnly: Value(false),
        ),
      );

  Future<EventsTableData> row(String id) =>
      (db.select(db.eventsTable)..where((t) => t.id.equals(id))).getSingle();

  /// A cached event with a policy, an occurrence and a roster of the current
  /// user alone, for [mark] to flag.
  Future<void> cacheOwned(String id, Future<void> Function(String) mark) async {
    await repo.cacheEvent(
      testSnapshot(
        id,
        policy: testPolicy(eventId: id),
        attendees: [testAttendee('att-me', userId: _kUserId, eventId: id)],
      ),
      source: EventAccessSource.attending,
    );
    await mark(id);
  }

  /// A read of [id] that disagrees with the cache everywhere: a new title, no
  /// occurrences, a roster of two, and another policy.
  Future<void> readDisagreeing(String id) => repo.cacheEvent(
    testSnapshot(
      id,
      title: 'Renamed on the server',
      occurrences: const [],
      policy: testPolicy(eventId: id).copyWith(maxAttendees: 99),
      attendees: [
        testAttendee('att-me', userId: _kUserId, eventId: id),
        testAttendee('att-other', userId: _kOtherUserId, eventId: id),
      ],
    ),
    source: EventAccessSource.attending,
  );

  Future<void> expectLeftAlone(
    String id, {
    required bool dirty,
    required bool localOnly,
  }) async {
    final snapshotBefore = await repo.getEvent(id);
    final rowBefore = await row(id);

    await readDisagreeing(id);

    // The title, occurrences, roster and policy, as one read of the cache.
    expect(await repo.getEvent(id), snapshotBefore);
    final after = await row(id);
    expect(after.title, 'Game night');
    expect(after.generation, rowBefore.generation);
    expect(after.isDirty, dirty);
    expect(after.isLocalOnly, localOnly);
    expect(after, rowBefore);
  }

  test('a read leaves a local-only event alone', () async {
    await cacheOwned('e-1', markLocalOnly);

    await expectLeftAlone('e-1', dirty: false, localOnly: true);
  });

  test('a read leaves a dirty event alone', () async {
    await cacheOwned('e-1', markDirty);

    await expectLeftAlone('e-1', dirty: true, localOnly: false);
  });

  test('a read does not take a generation for the event it leaves '
      'alone', () async {
    await cacheOwned('e-1', markLocalOnly);
    final counterBefore = await db.select(db.eventGenerationTable).getSingle();

    await readDisagreeing('e-1');

    expect(await db.select(db.eventGenerationTable).getSingle(), counterBefore);
  });

  test('a page writes the events beside a queue-owned one', () async {
    await cacheOwned('e-owned', markLocalOnly);
    final ownedBefore = await repo.getEvent('e-owned');
    final ownedRowBefore = await row('e-owned');

    await repo.cacheEvents([
      testSnapshot('e-owned', title: 'Renamed on the server'),
      testSnapshot('e-new', title: 'From the page'),
    ], source: EventAccessSource.attending);

    expect(await repo.getEvent('e-owned'), ownedBefore);
    expect(await row('e-owned'), ownedRowBefore);
    final written = await repo.getEvent('e-new');
    expect(written?.event.title, 'From the page');
    expect(written?.occurrences, hasLength(1));
    expect((await row('e-new')).generation, greaterThan(0));
  });

  test('a read after the flags clear writes again', () async {
    await cacheOwned('e-1', markLocalOnly);
    await markDirty('e-1');
    await readDisagreeing('e-1');
    expect((await row('e-1')).title, 'Game night');

    await clearFlags('e-1');
    await readDisagreeing('e-1');

    final snapshot = await repo.getEvent('e-1');
    expect(snapshot?.event.title, 'Renamed on the server');
    expect(snapshot?.occurrences, isEmpty);
    expect(snapshot?.policy?.maxAttendees, 99);
    expect(snapshot?.attendees?.map((a) => a.id), ['att-me', 'att-other']);
  });

  test('a page of only queue-owned events writes nothing', () async {
    await cacheOwned('e-1', markDirty);
    final counterBefore = await db.select(db.eventGenerationTable).getSingle();

    await repo.cacheEvents([
      testSnapshot('e-1', title: 'Renamed on the server'),
    ], source: EventAccessSource.attending);

    expect(await db.select(db.eventGenerationTable).getSingle(), counterBefore);
    expect((await row('e-1')).title, 'Game night');
  });

  test('a read inside a transaction of the caller writes with it, and leaves '
      'a queue-owned event alone', () async {
    await cacheOwned('e-owned', markLocalOnly);

    await db.transaction(() async {
      await repo.cacheEvent(
        testSnapshot('e-owned', title: 'Renamed on the server'),
        source: EventAccessSource.attending,
      );
      await repo.cacheEvent(
        testSnapshot('e-new', title: 'From inside'),
        source: EventAccessSource.attending,
      );
    });

    expect((await row('e-owned')).title, 'Game night');
    expect((await repo.getEvent('e-new'))?.event.title, 'From inside');
  });
}
