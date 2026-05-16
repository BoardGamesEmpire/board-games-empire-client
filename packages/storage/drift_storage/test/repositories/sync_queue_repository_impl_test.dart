import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';

const _kOperation = AddToCollectionOperation(
  localId: 'local-1',
  platformGameId: 'pg-1',
  medium: 'Physical',
  quantity: 1,
);

void main() {
  late ServerDatabase db;
  late SyncQueueRepositoryImpl repo;

  setUp(() {
    db = ServerDatabase.memory();
    repo = SyncQueueRepositoryImpl(db);
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
        // Seed with EXPLICIT timestamps so the ordering assertion is
        // unambiguous: two back-to-back repo.enqueue() calls can
        // land on the same microsecond on a fast machine, which
        // would let the pre-fix test (only `hasLength(2)`) silently
        // hide a real ordering regression.
        final older = DateTime.now().toUtc().subtract(const Duration(
              seconds: 10,
            ));
        final newer = DateTime.now().toUtc();

        await db.into(db.syncQueueTable).insert(
              SyncQueueTableCompanion.insert(
                id: 'queue-older',
                payload: _kOperation.serialized,
                status: const Value('pending'),
                createdAt: older,
              ),
            );
        await db.into(db.syncQueueTable).insert(
              SyncQueueTableCompanion.insert(
                id: 'queue-newer',
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

      test(
        'excludes inProgress entries (they go through resetStaleInProgress first)',
        () async {
          // getPendingEntries returns only 'pending' and 'failed'.
          // 'inProgress' entries are stuck if the worker died after
          // markInProgress — they need [resetStaleInProgress] on
          // startup to be retryable.
          final entry = await repo.enqueue(_kOperation);
          await repo.markInProgress(entry.id);

          expect(await repo.getPendingEntries(), isEmpty);
        },
      );
    });

    group('markInProgress()', () {
      test('sets status and records lastAttemptAt', () async {
        final entry = await repo.enqueue(_kOperation);
        await repo.markInProgress(entry.id);

        final updated = (await repo.getAllEntries()).first;
        expect(updated.status, SyncStatus.inProgress);
        expect(updated.lastAttemptAt, isNotNull);
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
          // Without the atomic UPDATE the prior implementation read
          // retry_count, then wrote retry_count + 1 in a second
          // statement. Two concurrent markFailed calls against the
          // same id could both read the same value and both write
          // value + 1, losing one increment.
          //
          // The fix uses a single UPDATE with a column expression
          // (`retry_count = retry_count + 1`) so each call sees the
          // post-image of the previous one.
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
    });

    group('resetStaleInProgress()', () {
      test(
        'resets all inProgress entries to pending and returns the affected count',
        () async {
          final a = await repo.enqueue(_kOperation);
          final b = await repo.enqueue(
            const UpdateCollectionOperation(collectionId: 'col-1'),
          );
          await repo.markInProgress(a.id);
          await repo.markInProgress(b.id);

          // Sanity: both inProgress.
          final pre = await repo.getAllEntries();
          expect(
            pre.where((e) => e.status == SyncStatus.inProgress),
            hasLength(2),
          );

          final reset = await repo.resetStaleInProgress();

          expect(reset, equals(2));
          final post = await repo.getAllEntries();
          expect(
            post.every((e) => e.status == SyncStatus.pending),
            isTrue,
          );
        },
      );

      test(
        'returns 0 and writes nothing when no entries are inProgress',
        () async {
          await repo.enqueue(_kOperation);

          final reset = await repo.resetStaleInProgress();

          expect(reset, equals(0));
          final entry = (await repo.getAllEntries()).first;
          expect(entry.status, SyncStatus.pending);
        },
      );

      test(
        'does not affect completed or failed entries',
        () async {
          final a = await repo.enqueue(_kOperation);
          final b = await repo.enqueue(
            const UpdateCollectionOperation(collectionId: 'col-1'),
          );
          await repo.markCompleted(a.id);
          await repo.markFailed(b.id, error: 'oops');

          final reset = await repo.resetStaleInProgress();
          expect(reset, equals(0));

          final byId = {
            for (final e in await repo.getAllEntries()) e.id: e,
          };
          expect(byId[a.id]!.status, SyncStatus.completed);
          expect(byId[b.id]!.status, SyncStatus.failed);
        },
      );

      test(
        'makes a crash-stuck inProgress entry retryable via getPendingEntries',
        () async {
          // The recovery use case end-to-end: an entry gets
          // markInProgress'd, the worker process dies before
          // markCompleted/markFailed, and on the next startup the
          // entry must end up back in the queue worker's pickup
          // list — not silently stuck forever.
          final entry = await repo.enqueue(_kOperation);
          await repo.markInProgress(entry.id);

          // Pre-reset: counted as pending by the badge, but the
          // worker's pickup query never sees it.
          expect(await repo.getPendingCount(), 1);
          expect(await repo.getPendingEntries(), isEmpty);

          await repo.resetStaleInProgress();

          // Post-reset: visible to the worker again.
          final pending = await repo.getPendingEntries();
          expect(pending.map((e) => e.id), equals([entry.id]));
          expect(pending.first.status, SyncStatus.pending);
        },
      );
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

    group('getPendingCount()', () {
      test('counts pending and in-progress entries', () async {
        final a = await repo.enqueue(_kOperation);
        final b = await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'col-1'),
        );

        await repo.markInProgress(b.id);

        expect(await repo.getPendingCount(), 2);
      });

      test('returns 0 when empty', () async {
        expect(await repo.getPendingCount(), 0);
      });
    });

    group('watchPendingCount()', () {
      test('emits the current pending count on subscribe', () async {
        // Empty queue → emits 0 immediately on subscribe.
        await expectLater(repo.watchPendingCount().take(1), emits(0));
      });

      test(
        'emits the current count when entries exist at subscribe time',
        () async {
          // Pass 3c change: the wrapper used to prepend a fake `yield 0`
          // before the real value. Now we get the actual current count
          // on first emission.
          await repo.enqueue(_kOperation);
          await expectLater(repo.watchPendingCount().take(1), emits(1));
        },
      );

      test(
        're-emits when an entry is enqueued after subscribe',
        () async {
          // Subscribe-then-mutate: take(2).toList() listens synchronously
          // and returns a Future that resolves when both emissions arrive.
          // The empty Future.delayed yields the event loop so Drift's
          // initial emission lands before the enqueue mutates the table.
          final futureEmissions =
              repo.watchPendingCount().take(2).toList();

          await Future<void>.delayed(Duration.zero);

          await repo.enqueue(_kOperation);

          expect(
            await futureEmissions.timeout(const Duration(seconds: 5)),
            equals([0, 1]),
          );
        },
      );
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
          lastPlayed: null,
        );
        final restored =
            SyncOperation.deserialize(op.serialized)
                as UpdateCollectionOperation;

        expect(restored.favorite, isTrue);
        expect(restored.lastPlayed, isNull);
      });

      test('RemoveFromCollectionOperation round-trips', () {
        const op = RemoveFromCollectionOperation(collectionId: 'col-2');
        final restored =
            SyncOperation.deserialize(op.serialized)
                as RemoveFromCollectionOperation;

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
          // Seed a row directly with a bogus status string, bypassing
          // the repo's write path. A future code-side enum extension
          // or DB corruption must surface here rather than be silently
          // coerced into 'pending' (which would cause the corrupt row
          // to be retried as a live sync op against the server).
          await db
              .into(db.syncQueueTable)
              .insert(
                SyncQueueTableCompanion.insert(
                  id: 'corrupt-1',
                  payload: '{}',
                  status: const Value('mystery-state'),
                  createdAt: DateTime.now().toUtc(),
                ),
              );

          await expectLater(
            repo.getAllEntries(),
            throwsA(isA<StateError>()),
          );
        },
      );

      test(
        'no longer accepts the legacy snake_case "in_progress" form',
        () async {
          // Pre-production, no v1-state DBs exist, so the
          // backwards-compat arm was dropped. The canonical wire form
          // is the camelCase [SyncStatus] name (`inProgress`).
          await db
              .into(db.syncQueueTable)
              .insert(
                SyncQueueTableCompanion.insert(
                  id: 'legacy-1',
                  payload: '{}',
                  status: const Value('in_progress'),
                  createdAt: DateTime.now().toUtc(),
                ),
              );

          await expectLater(
            repo.getAllEntries(),
            throwsA(isA<StateError>()),
          );
        },
      );
    });
  });
}
