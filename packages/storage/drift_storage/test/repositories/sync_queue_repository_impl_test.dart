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

      test(
        'tiebreaks deterministically by rowId when createdAt collides',
        () async {
          final t = DateTime.now().toUtc();
          for (final id in const ['op-a', 'op-b', 'op-c']) {
            await db.into(db.syncQueueTable).insert(
                  SyncQueueTableCompanion.insert(
                    id: id,
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

      test(
        'excludes inProgress entries (they go through resetStaleInProgress first)',
        () async {
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
          final entry = await repo.enqueue(_kOperation);
          await repo.markInProgress(entry.id);

          expect(await repo.getPendingCount(), 1);
          expect(await repo.getPendingEntries(), isEmpty);

          await repo.resetStaleInProgress();

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

    // ── remapCollectionId ─────────────────────────────────────────────────────────────

    group('remapCollectionId()', () {
      // Pass-7 commit 1: the sync-queue side of the fix for
      // Copilot fourth-pass thread 1. Locks in the behaviour
      // that lets reconcileFromServer rewrite pending Update /
      // Remove ops when the server reassigns the canonical id
      // of a collection row.

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
          final op =
              SyncOperation.deserialize(updated.payload)
                  as UpdateCollectionOperation;
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

          final op =
              SyncOperation.deserialize(
                    (await repo.getAllEntries()).single.payload,
                  )
                  as RemoveFromCollectionOperation;
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

          final op =
              SyncOperation.deserialize(
                    (await repo.getAllEntries()).single.payload,
                  )
                  as AddToCollectionOperation;
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
            const UpdateCollectionOperation(
              collectionId: 'local-X',
              rating: 8,
            ),
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

        final op =
            SyncOperation.deserialize(
                  (await repo.getAllEntries()).single.payload,
                )
                as UpdateCollectionOperation;
        expect(op.collectionId, equals('local-1'));
      });

      test('does not touch inProgress entries', () async {
        // Same rationale as completed — the worker has already sent
        // the op (or is sending it now) with the old id.
        // resetStaleInProgress is the only path back to retryable
        // for an inProgress entry; the remap should run AFTER that.
        final entry = await repo.enqueue(
          const RemoveFromCollectionOperation(collectionId: 'local-1'),
        );
        await repo.markInProgress(entry.id);

        final remapped = await repo.remapCollectionId(
          oldCollectionId: 'local-1',
          newCollectionId: 'server-99',
        );
        expect(remapped, equals(0));

        final op =
            SyncOperation.deserialize(
                  (await repo.getAllEntries()).single.payload,
                )
                as RemoveFromCollectionOperation;
        expect(op.collectionId, equals('local-1'));
      });

      test(
        'does not touch failed entries that exhausted maxRetries',
        () async {
          // Symmetric with getPendingEntries: once an entry has burned
          // its retry budget, the worker won't pick it up, and remap
          // shouldn't rewrite it either. The op is effectively dead
          // queue contents waiting to be purged.
          final entry = await repo.enqueue(
            const UpdateCollectionOperation(
              collectionId: 'local-1',
              rating: 1,
            ),
          );
          for (var i = 0; i < SyncQueueEntry.maxRetries; i++) {
            await repo.markFailed(entry.id, error: 'fail $i');
          }

          final remapped = await repo.remapCollectionId(
            oldCollectionId: 'local-1',
            newCollectionId: 'server-99',
          );
          expect(remapped, equals(0));

          final op =
              SyncOperation.deserialize(
                    (await repo.getAllEntries()).single.payload,
                  )
                  as UpdateCollectionOperation;
          expect(op.collectionId, equals('local-1'));
        },
      );

      test(
        'rewrites retryable failed entries (still outstanding work)',
        () async {
          // The retryable-failed case: the worker hit a transient
          // error, the entry is still in the pickup set, and the
          // server may now respond with a different canonical id
          // on the next attempt. The op must be rewritten so the
          // retry uses the new id.
          final entry = await repo.enqueue(
            const UpdateCollectionOperation(
              collectionId: 'local-1',
              rating: 6,
            ),
          );
          await repo.markFailed(entry.id, error: 'transient timeout');

          final remapped = await repo.remapCollectionId(
            oldCollectionId: 'local-1',
            newCollectionId: 'server-99',
          );
          expect(remapped, equals(1));

          final op =
              SyncOperation.deserialize(
                    (await repo.getAllEntries()).single.payload,
                  )
                  as UpdateCollectionOperation;
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
          const UpdateCollectionOperation(
            collectionId: 'local-1',
            rating: 5,
          ),
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

    group('getPendingCount() / watchPendingCount() — _pendingPredicate symmetry', () {
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

        await repo.markInProgress(b.id);

        expect(await repo.getPendingCount(), 2);
        expect((await repo.getAllEntries()).map((e) => e.id),
            unorderedEquals([a.id, b.id]));
      });

      test(
        'INCLUDES failed entries that have not exceeded maxRetries',
        () async {
          final entry = await repo.enqueue(_kOperation);
          await repo.markFailed(entry.id, error: 'timeout');

          expect(await repo.getPendingCount(), 1);
        },
      );

      test(
        'EXCLUDES failed entries that exhausted maxRetries',
        () async {
          final entry = await repo.enqueue(_kOperation);
          for (var i = 0; i < SyncQueueEntry.maxRetries; i++) {
            await repo.markFailed(entry.id, error: 'error $i');
          }

          expect(await repo.getPendingCount(), 0);
        },
      );

      test(
        'EXCLUDES pending entries with retryCount >= maxRetries '
        '(Pass-8 thread #1: post-resetStaleInProgress dead weight)',
        () async {
          // Reachable in production via:
          // 1. enqueue → markInProgress → markFailed (loop until
          //    retryCount == maxRetries-1, status=failed)
          // 2. a worker manually calls markInProgress on the failed
          //    row (for diagnostics or a manual retry attempt)
          // 3. the worker crashes
          // 4. resetStaleInProgress flips inProgress → pending
          //    WITHOUT touching retryCount
          //
          // Result: status='pending', retryCount=maxRetries-1. One
          // more failed cycle and we're at retryCount=maxRetries
          // still in pending after the next resetStaleInProgress.
          //
          // The pre-Pass-8 _pendingPredicate counted this row as
          // outstanding (status IN ('pending', 'inProgress') had
          // no retry guard) while getPendingEntries excluded it
          // (its retry guard applies to all retryable statuses).
          // Badge inflation by dead weight the worker can't touch.
          //
          // Direct-insert is the cleanest way to construct the
          // state; the multi-step path through the public API
          // produces the same row but at the cost of test
          // signal-to-noise.
          await db
              .into(db.syncQueueTable)
              .insert(
                SyncQueueTableCompanion.insert(
                  id: 'dead-pending',
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
        'EXCLUDES inProgress entries with retryCount >= maxRetries '
        '(Pass-8 thread #1: defensive)',
        () async {
          // Companion to the pending case. Not reachable through the
          // public API in normal flow (markInProgress doesn't touch
          // retryCount; markFailed sets status='failed' at the same
          // time it bumps retry), but a future code path or
          // direct-DB migration during the recovery scripts could
          // land it. The predicate must exclude it for the same
          // reason as the pending case: the worker won't pick it up
          // anyway, so the badge shouldn't pretend it's outstanding.
          await db
              .into(db.syncQueueTable)
              .insert(
                SyncQueueTableCompanion.insert(
                  id: 'dead-inprogress',
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
    });

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

      test(
        're-emits when an entry is enqueued after subscribe',
        () async {
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
