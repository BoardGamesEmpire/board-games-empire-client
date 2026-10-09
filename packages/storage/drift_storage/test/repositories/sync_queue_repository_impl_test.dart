import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';

import '../support/fixed_clock.dart';
import '../support/system_clock.dart';

const _kOperation = AddToCollectionOperation(
  localId: 'local-1',
  platformGameId: 'pg-1',
  medium: 'Physical',
  quantity: 1,
);

/// The user every repository instance in this file is scoped to (#147).
/// Raw companion inserts stamp the same id so the direct-insert fixtures
/// stay visible to the repository under test; cross-user scoping has its
/// own suite in `sync_queue_user_scoping_test.dart`.
const _kUserId = 'user-1';

void main() {
  late ServerDatabase db;
  late SyncQueueRepositoryImpl repo;

  setUp(() {
    db = inMemoryServerDatabase();
    // Real wall clock via the pass-through test double: these tests
    // predate #12 and exercise queue semantics, not timestamp origin
    // (the 'clock injection' group below covers that).
    repo = SyncQueueRepositoryImpl(
      db,
      const SystemClockService(),
      userId: _kUserId,
    );
  });

  tearDown(() async => db.close());

  group('SyncQueueRepositoryImpl', () {
    group('enqueue()', () {
      test('creates entry with pending status', () async {
        final entry = await repo.enqueue(_kOperation);

        expect(entry.status, SyncStatus.pending);
        expect(entry.retryCount, 0);
        expect(entry.isPending, isTrue);
      });

      test('deserializes payload back to correct operation type', () async {
        final entry = await repo.enqueue(_kOperation);
        final op = entry.operation;

        expect(op, isA<AddToCollectionOperation>());
        final add = op as AddToCollectionOperation;
        expect(add.platformGameId, 'pg-1');
        expect(add.medium, 'Physical');
      });
    });

    group('getPendingEntries()', () {
      test('returns pending entries in createdAt order', () async {
        final older = DateTime.now().toUtc().subtract(
          const Duration(seconds: 10),
        );
        final newer = DateTime.now().toUtc();

        await db
            .into(db.syncQueueTable)
            .insert(
              SyncQueueTableCompanion.insert(
                id: 'queue-older',
                userId: _kUserId,
                payload: _kOperation.serialized,
                status: const Value('pending'),
                createdAt: older,
              ),
            );
        await db
            .into(db.syncQueueTable)
            .insert(
              SyncQueueTableCompanion.insert(
                id: 'queue-newer',
                userId: _kUserId,
                payload: _kOperation.serialized,
                status: const Value('pending'),
                createdAt: newer,
              ),
            );

        final entries = await repo.getPendingEntries();
        expect(
          entries.map((e) => e.id),
          equals(['queue-older', 'queue-newer']),
        );
      });

      test(
        'tiebreaks deterministically by rowId when createdAt collides',
        () async {
          final t = DateTime.now().toUtc();
          for (final id in const ['op-a', 'op-b', 'op-c']) {
            await db
                .into(db.syncQueueTable)
                .insert(
                  SyncQueueTableCompanion.insert(
                    id: id,
                    userId: _kUserId,
                    payload: _kOperation.serialized,
                    status: const Value('pending'),
                    createdAt: t,
                  ),
                );
          }

          final entries = await repo.getPendingEntries();
          expect(entries.map((e) => e.id), equals(['op-a', 'op-b', 'op-c']));
        },
      );

      test('excludes completed entries', () async {
        final entry = await repo.enqueue(_kOperation);
        await repo.markCompleted(entry.id);

        expect(await repo.getPendingEntries(), isEmpty);
      });

      test(
        'includes failed entries that have not exceeded max retries',
        () async {
          final entry = await repo.enqueue(_kOperation);
          await repo.markFailed(entry.id, error: 'timeout');

          final pending = await repo.getPendingEntries();
          expect(pending, hasLength(1));
          expect(pending.first.status, SyncStatus.failed);
        },
      );

      test('excludes failed entries that exceeded max retries', () async {
        var entry = await repo.enqueue(_kOperation);

        for (var i = 0; i < SyncQueueEntry.maxRetries; i++) {
          await repo.markFailed(entry.id, error: 'error $i');
        }

        expect(await repo.getPendingEntries(), isEmpty);
      });

      test('excludes an entry whose claim is live', () async {
        final entry = await repo.enqueue(_kOperation);
        expect(await repo.claim(entry.id), isTrue);

        expect(await repo.getPendingEntries(), isEmpty);
      });

      test('includes an entry whose claim has expired (#430)', () async {
        // A sender that died mid-send leaves its claim behind. Once the
        // lease runs out the entry is claimable again, so the listing
        // returns it: the drain can't list what it can't claim, or miss
        // what it could.
        final clock = FixedClockService(DateTime.utc(2026, 10, 5, 12));
        final clockRepo = SyncQueueRepositoryImpl(
          db,
          clock,
          userId: _kUserId,
          localNowUtc: clock.nowUtc,
        );
        final live = await clockRepo.enqueue(_kOperation);
        final stale = await clockRepo.enqueue(_kOperation);
        expect(await clockRepo.claim(stale.id), isTrue);

        clock.current = clock.current.add(
          SyncQueueEntry.claimLease + const Duration(seconds: 1),
        );
        expect(await clockRepo.claim(live.id), isTrue);

        final pending = await clockRepo.getPendingEntries();
        expect(pending.map((e) => e.id), equals([stale.id]));
        expect(pending.single.status, SyncStatus.inProgress);
      });
    });

    group('queue order within one millisecond (#441)', () {
      // Stored as ISO-8601 text, the earlier instant is written
      // `…00.345Z` and the later `…00.345001Z`, which sorts first as
      // text. Each listing must still return the earlier op first.
      final earlier = DateTime.utc(2026, 10, 7, 12, 0, 0, 345);
      final later = DateTime.utc(2026, 10, 7, 12, 0, 0, 345, 1);
      late List<String> enqueued;
      late SyncQueueRepositoryImpl clockRepo;

      setUp(() async {
        final clock = FixedClockService(earlier);
        clockRepo = SyncQueueRepositoryImpl(db, clock, userId: _kUserId);
        final add = await clockRepo.enqueue(
          const AddToCollectionOperation(
            localId: 'gc-1',
            platformGameId: 'pg-1',
            medium: 'Physical',
            quantity: 1,
          ),
        );
        clock.current = later;
        final update = await clockRepo.enqueue(
          const UpdateCollectionOperation(collectionId: 'gc-1', rating: 9),
        );
        enqueued = [add.id, update.id];
      });

      test('getPendingEntries()', () async {
        final entries = await clockRepo.getPendingEntries();
        expect(entries.map((e) => e.id), enqueued);
      });

      test('getAllEntries()', () async {
        final entries = await clockRepo.getAllEntries();
        expect(entries.map((e) => e.id), enqueued);
      });

      test('getOutstandingOpsFor()', () async {
        final entries = await clockRepo.getOutstandingOpsFor('gc-1');
        expect(entries.map((e) => e.id), enqueued);
      });
    });

    group('queue order when enqueued out of time order (#441)', () {
      // Rowid only breaks ties. Here it would list the later op first,
      // enqueued first, so only `createdAt`, one millisecond earlier, can
      // list the other op first.
      final earlier = DateTime.utc(2026, 10, 7, 12, 0, 0, 345);
      final later = DateTime.utc(2026, 10, 7, 12, 0, 0, 346);
      late List<String> byCreatedAt;
      late SyncQueueRepositoryImpl clockRepo;

      setUp(() async {
        final clock = FixedClockService(later);
        clockRepo = SyncQueueRepositoryImpl(db, clock, userId: _kUserId);
        final stampedLater = await clockRepo.enqueue(
          const UpdateCollectionOperation(collectionId: 'gc-1', rating: 7),
        );
        clock.current = earlier;
        final stampedEarlier = await clockRepo.enqueue(
          const UpdateCollectionOperation(collectionId: 'gc-1', rating: 9),
        );
        byCreatedAt = [stampedEarlier.id, stampedLater.id];
      });

      test('getPendingEntries()', () async {
        final entries = await clockRepo.getPendingEntries();
        expect(entries.map((e) => e.id), byCreatedAt);
      });

      test('getAllEntries()', () async {
        final entries = await clockRepo.getAllEntries();
        expect(entries.map((e) => e.id), byCreatedAt);
      });

      test('getOutstandingOpsFor()', () async {
        final entries = await clockRepo.getOutstandingOpsFor('gc-1');
        expect(entries.map((e) => e.id), byCreatedAt);
      });
    });

    group('claim() (#430)', () {
      final start = DateTime.utc(2026, 10, 5, 12);
      late FixedClockService clock;
      late SyncQueueRepositoryImpl clockRepo;

      setUp(() {
        clock = FixedClockService(start);
        clockRepo = SyncQueueRepositoryImpl(
          db,
          clock,
          userId: _kUserId,
          localNowUtc: clock.nowUtc,
        );
      });

      Future<SyncQueueEntry> entryFor(String id) async =>
          (await clockRepo.getAllEntries()).singleWhere((e) => e.id == id);

      test(
        'takes a pending entry: inProgress, stamped with the clock',
        () async {
          final entry = await clockRepo.enqueue(_kOperation);

          expect(await clockRepo.claim(entry.id), isTrue);

          final claimed = await entryFor(entry.id);
          expect(claimed.status, SyncStatus.inProgress);
          expect(claimed.lastAttemptAt, start);
          expect(claimed.retryCount, 0);
        },
      );

      test('takes a retryable failed entry without touching its retry '
          'count or error', () async {
        final entry = await clockRepo.enqueue(_kOperation);
        await clockRepo.markFailed(entry.id, error: 'timeout');

        expect(await clockRepo.claim(entry.id), isTrue);

        final claimed = await entryFor(entry.id);
        expect(claimed.status, SyncStatus.inProgress);
        expect(claimed.retryCount, 1);
        expect(claimed.lastError, 'timeout');
      });

      test('refuses an entry whose claim is live, and leaves the claim '
          'alone', () async {
        final entry = await clockRepo.enqueue(_kOperation);
        expect(await clockRepo.claim(entry.id), isTrue);

        // Exactly one lease later is not yet "more than" a lease ago.
        clock.current = start.add(SyncQueueEntry.claimLease);
        expect(await clockRepo.claim(entry.id), isFalse);

        final held = await entryFor(entry.id);
        expect(held.status, SyncStatus.inProgress);
        expect(held.lastAttemptAt, start);
      });

      test('takes an entry back once its lease has expired', () async {
        final entry = await clockRepo.enqueue(_kOperation);
        expect(await clockRepo.claim(entry.id), isTrue);

        final later = start.add(
          SyncQueueEntry.claimLease + const Duration(seconds: 1),
        );
        clock.current = later;
        expect(await clockRepo.claim(entry.id), isTrue);

        expect((await entryFor(entry.id)).lastAttemptAt, later);
      });

      test('judges the lease correctly at microsecond precision', () async {
        // Stored as ISO-8601 text, a stamp with sub-millisecond digits is
        // written with six fractional digits and one without them with
        // three. The comparison must treat both as instants: a parse
        // failure would make every claim look live forever.
        final precise = DateTime.utc(2026, 10, 5, 12, 0, 0, 123, 456);
        clock.current = precise;
        final entry = await clockRepo.enqueue(_kOperation);
        expect(await clockRepo.claim(entry.id), isTrue);

        clock.current = precise.add(SyncQueueEntry.claimLease);
        expect(await clockRepo.claim(entry.id), isFalse);

        clock.current = precise.add(
          SyncQueueEntry.claimLease + const Duration(milliseconds: 1),
        );
        expect(await clockRepo.claim(entry.id), isTrue);
      });

      test('treats an inProgress entry with no attempt stamp as '
          'expired', () async {
        // Not producible through `claim`, which always stamps. A row in
        // this state would otherwise be stuck: counted as outstanding,
        // never listed, never claimable.
        await db
            .into(db.syncQueueTable)
            .insert(
              SyncQueueTableCompanion.insert(
                id: 'unstamped',
                userId: _kUserId,
                payload: _kOperation.serialized,
                status: const Value('inProgress'),
                createdAt: start,
              ),
            );

        expect(await clockRepo.claim('unstamped'), isTrue);
      });

      test('refuses a completed entry', () async {
        final entry = await clockRepo.enqueue(_kOperation);
        await clockRepo.markCompleted(entry.id);

        expect(await clockRepo.claim(entry.id), isFalse);
        expect((await entryFor(entry.id)).status, SyncStatus.completed);
      });

      test('refuses an entry that exhausted its retries', () async {
        final entry = await clockRepo.enqueue(_kOperation);
        for (var i = 0; i < SyncQueueEntry.maxRetries; i++) {
          await clockRepo.markFailed(entry.id, error: 'error $i');
        }

        expect(await clockRepo.claim(entry.id), isFalse);
        expect((await entryFor(entry.id)).status, SyncStatus.failed);
      });

      test('returns false for an unknown id', () async {
        expect(await clockRepo.claim('nonexistent'), isFalse);
      });

      test('exactly one of two concurrent claims wins', () async {
        // Two senders over one database: a drain and the inline household
        // send, or two web tabs. On the VM this pins the predicate. That
        // it holds across tabs rests on drift's durable web storage modes
        // serializing access (#430).
        final other = SyncQueueRepositoryImpl(
          db,
          clock,
          userId: _kUserId,
          localNowUtc: clock.nowUtc,
        );
        final entry = await clockRepo.enqueue(_kOperation);

        final results = await Future.wait([
          clockRepo.claim(entry.id),
          other.claim(entry.id),
        ]);

        expect(results.where((won) => won), hasLength(1));
      });

      test('judges the lease by the device clock, not the server-corrected '
          'one', () async {
        // The corrected clock steps when a skew estimate lands, and each web
        // tab estimates its own. Neither may move a lease between senders on
        // one device, which all read the same device clock.
        final serverClock = FixedClockService(start);
        final skewed = SyncQueueRepositoryImpl(
          db,
          serverClock,
          userId: _kUserId,
          localNowUtc: clock.nowUtc,
        );
        final entry = await skewed.enqueue(_kOperation);
        expect(await skewed.claim(entry.id), isTrue);

        // A slow device's first correction steps the corrected clock ahead.
        serverClock.current = start.add(const Duration(minutes: 5));
        expect(await skewed.claim(entry.id), isFalse, reason: 'still live');

        // A fast device's correction holds it still while time passes.
        serverClock.current = start;
        clock.current = start.add(
          SyncQueueEntry.claimLease + const Duration(seconds: 1),
        );
        expect(await skewed.claim(entry.id), isTrue, reason: 'expired');
      });
    });

    group('release() (#430)', () {
      test('returns a claimed entry to pending without counting a '
          'retry', () async {
        final entry = await repo.enqueue(_kOperation);
        expect(await repo.claim(entry.id), isTrue);

        await repo.release(entry.id);

        final released = (await repo.getAllEntries()).single;
        expect(released.status, SyncStatus.pending);
        expect(released.retryCount, 0);
        expect(released.lastError, isNull);
        expect((await repo.getPendingEntries()).map((e) => e.id), [entry.id]);
      });

      test('does not reopen a completed entry', () async {
        final entry = await repo.enqueue(_kOperation);
        expect(await repo.claim(entry.id), isTrue);
        await repo.markCompleted(entry.id);

        await repo.release(entry.id);

        expect(
          (await repo.getAllEntries()).single.status,
          SyncStatus.completed,
        );
      });

      test('leaves a failed entry failed', () async {
        final entry = await repo.enqueue(_kOperation);
        await repo.markFailed(entry.id, error: 'timeout');

        await repo.release(entry.id);

        final failed = (await repo.getAllEntries()).single;
        expect(failed.status, SyncStatus.failed);
        expect(failed.retryCount, 1);
      });

      test('is a no-op for an unknown id', () async {
        await repo.release('nonexistent');
        expect(await repo.getAllEntries(), isEmpty);
      });
    });

    group('markCompleted()', () {
      test('sets status to completed', () async {
        final entry = await repo.enqueue(_kOperation);
        await repo.markCompleted(entry.id);

        final updated = (await repo.getAllEntries()).first;
        expect(updated.status, SyncStatus.completed);
      });
    });

    group('markFailed()', () {
      test('increments retry count and stores error', () async {
        final entry = await repo.enqueue(_kOperation);
        await repo.markFailed(entry.id, error: 'network error');

        final updated = (await repo.getAllEntries()).first;
        expect(updated.retryCount, 1);
        expect(updated.lastError, 'network error');
        expect(updated.status, SyncStatus.failed);
      });

      test(
        'atomic increment: concurrent markFailed calls do not lose retries',
        () async {
          final entry = await repo.enqueue(_kOperation);

          const concurrent = 5;
          await Future.wait(
            List.generate(
              concurrent,
              (i) => repo.markFailed(entry.id, error: 'fail $i'),
            ),
          );

          final updated = (await repo.getAllEntries()).first;
          expect(updated.retryCount, equals(concurrent));
          expect(updated.status, SyncStatus.failed);
        },
      );

      test('is a no-op when the id does not exist', () async {
        await repo.markFailed('nonexistent', error: 'oops');
        expect(await repo.getAllEntries(), isEmpty);
      });

      test('does not reopen a completed entry (#430)', () async {
        // A sender whose lease expired can still be waiting on its request
        // after another sender delivered the op and completed it. Its
        // failure must not queue the op again: a re-sent add or update
        // would overwrite whatever the user changed since.
        final entry = await repo.enqueue(_kOperation);
        expect(await repo.claim(entry.id), isTrue);
        await repo.markCompleted(entry.id);

        await repo.markFailed(entry.id, error: 'timeout');

        final completed = (await repo.getAllEntries()).single;
        expect(completed.status, SyncStatus.completed);
        expect(completed.retryCount, 0);
        expect(completed.lastError, isNull);
        expect(await repo.getPendingEntries(), isEmpty);
      });
    });

    group('purgeCompleted()', () {
      test('removes completed entries and returns count', () async {
        final a = await repo.enqueue(_kOperation);
        await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'col-1'),
        );
        await repo.markCompleted(a.id);

        final purged = await repo.purgeCompleted();
        expect(purged, 1);
        expect(await repo.getAllEntries(), hasLength(1));
      });
    });

    // ── remapCollectionId ─────────────────────────────────────────────────────────────

    group('remapCollectionId()', () {
      test(
        'rewrites a pending UpdateCollectionOperation that targets oldId',
        () async {
          final entry = await repo.enqueue(
            const UpdateCollectionOperation(
              collectionId: 'local-1',
              rating: 9,
              favorite: true,
            ),
          );

          final remapped = await repo.remapCollectionId(
            oldCollectionId: 'local-1',
            newCollectionId: 'server-99',
          );
          expect(remapped, equals(1));

          final updated = (await repo.getAllEntries()).single;
          expect(updated.id, equals(entry.id));
          final op = SyncOperation.deserialize(
            updated.payload,
          ) as UpdateCollectionOperation;
          expect(op.collectionId, equals('server-99'));
          // Other fields preserved.
          expect(op.rating, equals(9));
          expect(op.favorite, isTrue);
        },
      );

      test(
        'rewrites a pending RemoveFromCollectionOperation that targets oldId',
        () async {
          await repo.enqueue(
            const RemoveFromCollectionOperation(collectionId: 'local-1'),
          );

          final remapped = await repo.remapCollectionId(
            oldCollectionId: 'local-1',
            newCollectionId: 'server-99',
          );
          expect(remapped, equals(1));

          final op = SyncOperation.deserialize(
            (await repo.getAllEntries()).single.payload,
          ) as RemoveFromCollectionOperation;
          expect(op.collectionId, equals('server-99'));
        },
      );

      test(
        'rewrites a pending AddToCollectionOperation whose localId == oldId',
        () async {
          // The localId on AddToCollectionOperation is informational
          // (the server uses it for reconciliation echo), but we still
          // keep it consistent with the canonical id so the queue's
          // serialised form doesn't lie about which local row it
          // created.
          await repo.enqueue(
            const AddToCollectionOperation(
              localId: 'local-1',
              platformGameId: 'pg-7',
              medium: 'Digital',
              quantity: 1,
            ),
          );

          final remapped = await repo.remapCollectionId(
            oldCollectionId: 'local-1',
            newCollectionId: 'server-99',
          );
          expect(remapped, equals(1));

          final op = SyncOperation.deserialize(
            (await repo.getAllEntries()).single.payload,
          ) as AddToCollectionOperation;
          expect(op.localId, equals('server-99'));
          expect(op.platformGameId, equals('pg-7'));
          expect(op.medium, equals('Digital'));
        },
      );

      test(
        'rewrites every retryable entry that targets oldId in a single call',
        () async {
          // End-to-end scenario the production callsite exercises:
          // user added + updated + removed a single local-only row,
          // all three ops are queued, then the server reassigns the
          // id. All three must be rewritten in one go.
          await repo.enqueue(
            const AddToCollectionOperation(
              localId: 'local-X',
              platformGameId: 'pg-1',
              medium: 'Physical',
              quantity: 1,
            ),
          );
          await repo.enqueue(
            const UpdateCollectionOperation(collectionId: 'local-X', rating: 8),
          );
          await repo.enqueue(
            const RemoveFromCollectionOperation(collectionId: 'local-X'),
          );

          final remapped = await repo.remapCollectionId(
            oldCollectionId: 'local-X',
            newCollectionId: 'server-Y',
          );
          expect(remapped, equals(3));

          final entries = await repo.getAllEntries();
          final ids = entries
              .map((e) => SyncOperation.deserialize(e.payload))
              .map(
                (op) => switch (op) {
                  AddToCollectionOperation() => op.localId,
                  UpdateCollectionOperation() => op.collectionId,
                  RemoveFromCollectionOperation() => op.collectionId,
                  CreateHouseholdOperation() => op.localId,
                },
              )
              .toList();
          expect(ids, everyElement(equals('server-Y')));
        },
      );

      test('leaves ops that do not target oldId untouched', () async {
        // Mix of targets — only the local-1 ops should be rewritten.
        await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'local-1', rating: 5),
        );
        await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'other-id', rating: 7),
        );
        await repo.enqueue(
          const RemoveFromCollectionOperation(collectionId: 'unrelated'),
        );

        final remapped = await repo.remapCollectionId(
          oldCollectionId: 'local-1',
          newCollectionId: 'server-99',
        );
        expect(remapped, equals(1));

        final targets = (await repo.getAllEntries())
            .map((e) => SyncOperation.deserialize(e.payload))
            .map(
              (op) => switch (op) {
                AddToCollectionOperation() => op.localId,
                UpdateCollectionOperation() => op.collectionId,
                RemoveFromCollectionOperation() => op.collectionId,
                CreateHouseholdOperation() => op.localId,
              },
            )
            .toSet();
        expect(targets, equals({'server-99', 'other-id', 'unrelated'}));
      });

      test('does not touch completed entries', () async {
        // The op already shipped to the server with the old id and
        // got confirmed. Rewriting now would put the queue out of
        // sync with what the server already accepted.
        final entry = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'local-1', rating: 9),
        );
        await repo.markCompleted(entry.id);

        final remapped = await repo.remapCollectionId(
          oldCollectionId: 'local-1',
          newCollectionId: 'server-99',
        );
        expect(remapped, equals(0));

        final op = SyncOperation.deserialize(
          (await repo.getAllEntries()).single.payload,
        ) as UpdateCollectionOperation;
        expect(op.collectionId, equals('local-1'));
      });

      test('rewrites an entry whose claim is live (#429)', () async {
        // The request already on the wire keeps the old id; rewriting
        // can't change that. But if that send fails, the retry must carry
        // the id the server knows, and the entry's later acknowledgements
        // must find the op under it. Left on the old id, the op would
        // drop out of both.
        final entry = await repo.enqueue(
          const RemoveFromCollectionOperation(collectionId: 'local-1'),
        );
        expect(await repo.claim(entry.id), isTrue);

        final remapped = await repo.remapCollectionId(
          oldCollectionId: 'local-1',
          newCollectionId: 'server-99',
        );
        expect(remapped, equals(1));

        final held = (await repo.getAllEntries()).single;
        expect(held.status, SyncStatus.inProgress, reason: 'claim untouched');
        final op = SyncOperation.deserialize(
          held.payload,
        ) as RemoveFromCollectionOperation;
        expect(op.collectionId, equals('server-99'));
      });

      test('rewrites an entry whose claim has expired (#430)', () async {
        // An expired claim is claimable again, so its next send must
        // carry the new id.
        final clock = FixedClockService(DateTime.utc(2026, 10, 5, 12));
        final clockRepo = SyncQueueRepositoryImpl(
          db,
          clock,
          userId: _kUserId,
          localNowUtc: clock.nowUtc,
        );
        final entry = await clockRepo.enqueue(
          const RemoveFromCollectionOperation(collectionId: 'local-1'),
        );
        expect(await clockRepo.claim(entry.id), isTrue);
        clock.current = clock.current.add(
          SyncQueueEntry.claimLease + const Duration(seconds: 1),
        );

        final remapped = await clockRepo.remapCollectionId(
          oldCollectionId: 'local-1',
          newCollectionId: 'server-99',
        );
        expect(remapped, equals(1));

        final op = SyncOperation.deserialize(
          (await clockRepo.getAllEntries()).single.payload,
        ) as RemoveFromCollectionOperation;
        expect(op.collectionId, equals('server-99'));
      });

      test('rewrites an entry that exhausted maxRetries (#429)', () async {
        // The worker won't send it again, but it is still the entry's
        // change that never landed: an acknowledgement keeps the entry
        // dirty while it remains, and finds it by the entry's current id.
        // A hand retry (#190) would need that id too.
        final entry = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'local-1', rating: 1),
        );
        for (var i = 0; i < SyncQueueEntry.maxRetries; i++) {
          await repo.markFailed(entry.id, error: 'fail $i');
        }

        final remapped = await repo.remapCollectionId(
          oldCollectionId: 'local-1',
          newCollectionId: 'server-99',
        );
        expect(remapped, equals(1));

        final op = SyncOperation.deserialize(
          (await repo.getAllEntries()).single.payload,
        ) as UpdateCollectionOperation;
        expect(op.collectionId, equals('server-99'));
      });

      test(
        'rewrites retryable failed entries (still outstanding work)',
        () async {
          // The retryable-failed case: the worker hit a transient
          // error, the entry is still in the pickup set, and the
          // server may now respond with a different canonical id
          // on the next attempt. The op must be rewritten so the
          // retry uses the new id.
          final entry = await repo.enqueue(
            const UpdateCollectionOperation(collectionId: 'local-1', rating: 6),
          );
          await repo.markFailed(entry.id, error: 'transient timeout');

          final remapped = await repo.remapCollectionId(
            oldCollectionId: 'local-1',
            newCollectionId: 'server-99',
          );
          expect(remapped, equals(1));

          final op = SyncOperation.deserialize(
            (await repo.getAllEntries()).single.payload,
          ) as UpdateCollectionOperation;
          expect(op.collectionId, equals('server-99'));
        },
      );

      test('is a no-op when oldId == newId', () async {
        // Defensive short-circuit. The production callsite already
        // guards against this (reconcileFromServer only calls remap
        // when local.id != serverEntry.id), but the contract should
        // also be safe in isolation: a redundant remap shouldn't
        // re-serialise the payload and re-bump updatedAt-like state.
        await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'local-1', rating: 5),
        );

        final remapped = await repo.remapCollectionId(
          oldCollectionId: 'local-1',
          newCollectionId: 'local-1',
        );
        expect(remapped, equals(0));
      });

      test('returns 0 when no entries reference oldId', () async {
        await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'other-id'),
        );
        await repo.enqueue(
          const RemoveFromCollectionOperation(collectionId: 'unrelated'),
        );

        final remapped = await repo.remapCollectionId(
          oldCollectionId: 'local-1',
          newCollectionId: 'server-99',
        );
        expect(remapped, equals(0));
      });

      test('returns 0 when the queue is empty', () async {
        final remapped = await repo.remapCollectionId(
          oldCollectionId: 'local-1',
          newCollectionId: 'server-99',
        );
        expect(remapped, equals(0));
      });
    });

    // ── getOutstandingOpsFor ────────────────────────────────────────────────────

    group('getOutstandingOpsFor() (#429)', () {
      List<String> idsOf(List<SyncQueueEntry> entries) =>
          entries.map((e) => e.id).toList();

      test('returns every op targeting the id, in queue order, across all '
          'three op types', () async {
        final add = await repo.enqueue(
          const AddToCollectionOperation(
            localId: 'gc-1',
            platformGameId: 'pg-1',
            medium: 'Physical',
            quantity: 1,
          ),
        );
        final update = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'gc-1', rating: 9),
        );
        final remove = await repo.enqueue(
          const RemoveFromCollectionOperation(collectionId: 'gc-1'),
        );

        final entries = await repo.getOutstandingOpsFor('gc-1');

        expect(idsOf(entries), [add.id, update.id, remove.id]);
      });

      test('finds every op the remap moved, under the new id', () async {
        // The remap and the lookup cover the same set, so an
        // acknowledgement after a reassignment sees claimed and exhausted
        // ops as well as pending ones.
        final claimed = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'local-1', rating: 1),
        );
        final exhausted = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'local-1', rating: 2),
        );
        expect(await repo.claim(claimed.id), isTrue);
        for (var i = 0; i < SyncQueueEntry.maxRetries; i++) {
          await repo.markFailed(exhausted.id, error: 'error $i');
        }

        await repo.remapCollectionId(
          oldCollectionId: 'local-1',
          newCollectionId: 'server-1',
        );

        expect(idsOf(await repo.getOutstandingOpsFor('server-1')), [
          claimed.id,
          exhausted.id,
        ]);
        expect(await repo.getOutstandingOpsFor('local-1'), isEmpty);
      });

      test('includes claimed, failed and exhausted ops — everything not '
          'completed', () async {
        // An exhausted op still says the user's change didn't land, and a
        // claimed one may not land either: an acknowledgement must not
        // report the entry as synced while either remains (#429).
        final claimed = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'gc-1', rating: 1),
        );
        final failed = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'gc-1', rating: 2),
        );
        final exhausted = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'gc-1', rating: 3),
        );
        final completed = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'gc-1', rating: 4),
        );
        expect(await repo.claim(claimed.id), isTrue);
        await repo.markFailed(failed.id, error: 'timeout');
        for (var i = 0; i < SyncQueueEntry.maxRetries; i++) {
          await repo.markFailed(exhausted.id, error: 'error $i');
        }
        await repo.markCompleted(completed.id);

        final entries = await repo.getOutstandingOpsFor('gc-1');

        expect(idsOf(entries), [claimed.id, failed.id, exhausted.id]);
      });

      test('leaves out ops for other entries and household ops', () async {
        await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'other', rating: 1),
        );
        await repo.enqueue(
          const CreateHouseholdOperation(localId: 'gc-1', name: 'HQ'),
        );
        final mine = await repo.enqueue(
          const RemoveFromCollectionOperation(collectionId: 'gc-1'),
        );

        final entries = await repo.getOutstandingOpsFor('gc-1');

        expect(idsOf(entries), [mine.id]);
      });

      test('returns the entry named by `including` in its place, even once '
          'completed', () async {
        // An acknowledgement places the op it acknowledges among the others.
        // A second delivery's acknowledgement finds that op completed by the
        // first, and must still be able to place it.
        final before = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'gc-1', rating: 1),
        );
        final acknowledged = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'gc-1', rating: 2),
        );
        final after = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'gc-1', rating: 3),
        );
        final otherCompleted = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'gc-1', rating: 4),
        );
        await repo.markCompleted(acknowledged.id);
        await repo.markCompleted(otherCompleted.id);

        final entries = await repo.getOutstandingOpsFor(
          'gc-1',
          including: acknowledged.id,
        );

        expect(idsOf(entries), [before.id, acknowledged.id, after.id]);
      });

      test('`including` adds nothing for an entry that targets another '
          'collection entry', () async {
        final elsewhere = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'other', rating: 1),
        );
        final mine = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'gc-1', rating: 2),
        );

        final entries = await repo.getOutstandingOpsFor(
          'gc-1',
          including: elsewhere.id,
        );

        expect(idsOf(entries), [mine.id]);
      });

      test('skips a payload it cannot parse', () async {
        await db
            .into(db.syncQueueTable)
            .insert(
              SyncQueueTableCompanion.insert(
                id: 'corrupt',
                userId: _kUserId,
                payload: '{"type":"unknown_op"}',
                createdAt: DateTime.now().toUtc(),
              ),
            );
        final mine = await repo.enqueue(
          const RemoveFromCollectionOperation(collectionId: 'gc-1'),
        );

        final entries = await repo.getOutstandingOpsFor('gc-1');

        expect(idsOf(entries), [mine.id]);
      });
    });

    group(
      'getPendingCount() / watchPendingCount() — _pendingPredicate symmetry',
      () {
        test('counts pending entries', () async {
          await repo.enqueue(_kOperation);
          await repo.enqueue(
            const UpdateCollectionOperation(collectionId: 'col-1'),
          );

          expect(await repo.getPendingCount(), 2);
        });

        test('counts inProgress entries (still outstanding work)', () async {
          final a = await repo.enqueue(_kOperation);
          final b = await repo.enqueue(
            const UpdateCollectionOperation(collectionId: 'col-1'),
          );

          expect(await repo.claim(b.id), isTrue);

          expect(await repo.getPendingCount(), 2);
          expect(
            (await repo.getAllEntries()).map((e) => e.id),
            unorderedEquals([a.id, b.id]),
          );
        });

        test(
          'INCLUDES failed entries that have not exceeded maxRetries',
          () async {
            final entry = await repo.enqueue(_kOperation);
            await repo.markFailed(entry.id, error: 'timeout');

            expect(await repo.getPendingCount(), 1);
          },
        );

        test('EXCLUDES failed entries that exhausted maxRetries', () async {
          final entry = await repo.enqueue(_kOperation);
          for (var i = 0; i < SyncQueueEntry.maxRetries; i++) {
            await repo.markFailed(entry.id, error: 'error $i');
          }

          expect(await repo.getPendingCount(), 0);
        });

        test(
          'EXCLUDES pending entries with retryCount >= maxRetries',
          () async {
            // Not reachable through the public API: markFailed sets
            // status='failed' in the same write that bumps the count,
            // and claim and release refuse an exhausted entry. A
            // direct-DB repair or a future code path could still land
            // it, and the predicate must exclude it: the worker won't
            // pick it up, so the badge shouldn't count it.
            await db
                .into(db.syncQueueTable)
                .insert(
                  SyncQueueTableCompanion.insert(
                    id: 'dead-pending',
                    userId: _kUserId,
                    payload: _kOperation.serialized,
                    status: const Value('pending'),
                    retryCount: const Value(SyncQueueEntry.maxRetries),
                    createdAt: DateTime.now().toUtc(),
                  ),
                );

            // Predicate-driven count: row excluded.
            expect(await repo.getPendingCount(), 0);
            // Watch stream agrees: same predicate.
            await expectLater(repo.watchPendingCount().take(1), emits(0));
            // Worker pickup set agrees: same retry cap. Locks in the
            // symmetry between the two predicates.
            expect(await repo.getPendingEntries(), isEmpty);
          },
        );

        test(
          'EXCLUDES inProgress entries with retryCount >= maxRetries',
          () async {
            // Companion to the pending case. Not reachable through the
            // public API in normal flow (claim refuses an exhausted
            // entry; markFailed sets status='failed' at the same time
            // it bumps retry), but a future code path or direct-DB
            // migration during the recovery scripts could land it. The
            // predicate must exclude it for the same reason as the
            // pending case: the worker won't pick it up anyway, so the
            // badge shouldn't pretend it's outstanding.
            await db
                .into(db.syncQueueTable)
                .insert(
                  SyncQueueTableCompanion.insert(
                    id: 'dead-inprogress',
                    userId: _kUserId,
                    payload: _kOperation.serialized,
                    status: const Value('inProgress'),
                    retryCount: const Value(SyncQueueEntry.maxRetries),
                    createdAt: DateTime.now().toUtc(),
                  ),
                );

            expect(await repo.getPendingCount(), 0);
            await expectLater(repo.watchPendingCount().take(1), emits(0));
          },
        );

        test('excludes completed entries', () async {
          final entry = await repo.enqueue(_kOperation);
          await repo.markCompleted(entry.id);

          expect(await repo.getPendingCount(), 0);
        });

        test('returns 0 when empty', () async {
          expect(await repo.getPendingCount(), 0);
        });

        test(
          'watchPendingCount also includes retryable failed entries',
          () async {
            final entry = await repo.enqueue(_kOperation);
            await repo.markFailed(entry.id, error: 'timeout');

            await expectLater(repo.watchPendingCount().take(1), emits(1));
          },
        );
      },
    );

    group('watchPendingCount()', () {
      test('emits the current pending count on subscribe', () async {
        await expectLater(repo.watchPendingCount().take(1), emits(0));
      });

      test(
        'emits the current count when entries exist at subscribe time',
        () async {
          await repo.enqueue(_kOperation);
          await expectLater(repo.watchPendingCount().take(1), emits(1));
        },
      );

      test('re-emits when an entry is enqueued after subscribe', () async {
        final futureEmissions = repo.watchPendingCount().take(2).toList();

        await Future<void>.delayed(Duration.zero);

        await repo.enqueue(_kOperation);

        expect(
          await futureEmissions.timeout(const Duration(seconds: 5)),
          equals([0, 1]),
        );
      });
    });

    group('SyncOperation round-trip', () {
      test('AddToCollectionOperation serializes and deserializes', () {
        const op = AddToCollectionOperation(
          localId: 'l-1',
          platformGameId: 'pg-2',
          medium: 'Digital',
          quantity: 2,
          rating: 8,
        );
        final restored = SyncOperation.deserialize(op.serialized);

        expect(restored, isA<AddToCollectionOperation>());
        final add = restored as AddToCollectionOperation;
        expect(add.rating, 8);
        expect(add.medium, 'Digital');
      });

      test('UpdateCollectionOperation round-trips with nullable fields', () {
        const op = UpdateCollectionOperation(
          collectionId: 'col-1',
          favorite: true,
        );
        final restored = SyncOperation.deserialize(
          op.serialized,
        ) as UpdateCollectionOperation;

        expect(restored.favorite, isTrue);
        expect(restored.rating, isNull);
      });

      test('RemoveFromCollectionOperation round-trips', () {
        const op = RemoveFromCollectionOperation(collectionId: 'col-2');
        final restored = SyncOperation.deserialize(
          op.serialized,
        ) as RemoveFromCollectionOperation;

        expect(restored.collectionId, 'col-2');
      });

      test('throws FormatException for unknown type', () {
        expect(
          () => SyncOperation.deserialize('{"type":"unknown_op"}'),
          throwsA(isA<FormatException>()),
        );
      });
    });

    group('_parseStatus (via row mapping)', () {
      test(
        'throws StateError on a corrupt or unknown status value in the DB',
        () async {
          await db
              .into(db.syncQueueTable)
              .insert(
                SyncQueueTableCompanion.insert(
                  id: 'corrupt-1',
                  userId: _kUserId,
                  payload: '{}',
                  status: const Value('mystery-state'),
                  createdAt: DateTime.now().toUtc(),
                ),
              );

          await expectLater(repo.getAllEntries(), throwsA(isA<StateError>()));
        },
      );

      test(
        'no longer accepts the legacy snake_case "in_progress" form',
        () async {
          await db
              .into(db.syncQueueTable)
              .insert(
                SyncQueueTableCompanion.insert(
                  id: 'legacy-1',
                  userId: _kUserId,
                  payload: '{}',
                  status: const Value('in_progress'),
                  createdAt: DateTime.now().toUtc(),
                ),
              );

          await expectLater(repo.getAllEntries(), throwsA(isA<StateError>()));
        },
      );
    });

    group('clock injection (#12)', () {
      final fixed = DateTime.utc(2026, 7, 21, 12);

      test('enqueue createdAt comes from the injected clock', () async {
        final clockRepo = SyncQueueRepositoryImpl(
          db,
          FixedClockService(fixed),
          userId: _kUserId,
        );

        final entry = await clockRepo.enqueue(_kOperation);

        expect(entry.createdAt, fixed);
      });

      // Attempt stamps are the device's own time, not the server-corrected
      // time: the claim lease is judged by them (#430).
      test('claim stamps lastAttemptAt from the device clock', () async {
        final device = FixedClockService(fixed.add(const Duration(minutes: 1)));
        final clockRepo = SyncQueueRepositoryImpl(
          db,
          FixedClockService(fixed),
          userId: _kUserId,
          localNowUtc: device.nowUtc,
        );
        final entry = await clockRepo.enqueue(_kOperation);

        expect(await clockRepo.claim(entry.id), isTrue);

        final updated = (await clockRepo.getAllEntries()).single;
        expect(updated.lastAttemptAt, fixed.add(const Duration(minutes: 1)));
      });

      test('markFailed stamps lastAttemptAt from the device clock', () async {
        final device = FixedClockService(fixed.add(const Duration(minutes: 2)));
        final clockRepo = SyncQueueRepositoryImpl(
          db,
          FixedClockService(fixed),
          userId: _kUserId,
          localNowUtc: device.nowUtc,
        );
        final entry = await clockRepo.enqueue(_kOperation);

        await clockRepo.markFailed(entry.id, error: 'boom');

        final updated = (await clockRepo.getAllEntries()).single;
        expect(updated.lastAttemptAt, fixed.add(const Duration(minutes: 2)));
      });
    });
  });
}
