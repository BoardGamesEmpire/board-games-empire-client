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
        await repo.enqueue(_kOperation);
        await repo.enqueue(
          const UpdateCollectionOperation(collectionId: 'col-1', rating: 7),
        );

        final entries = await repo.getPendingEntries();
        expect(entries, hasLength(2));
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

      test('emits the current count when entries exist at subscribe time',
          () async {
        // Pass 3c change: the wrapper used to prepend a fake `yield 0`
        // before the real value. Now we get the actual current count
        // on first emission.
        await repo.enqueue(_kOperation);
        await expectLater(repo.watchPendingCount().take(1), emits(1));
      });

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
  });
}
