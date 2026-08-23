import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';

import '../support/fixed_clock.dart';

/// #147 acceptance: the sync queue is data-scoped to the enqueuing user.
///
/// The table is server-wide (that per-server storage is what makes D8
/// survival work — see `../composition/sync_queue_rejection_survival_test`),
/// but every repository instance is built for one user and can neither
/// observe nor mutate another user's rows. These tests run two repository
/// instances over ONE in-memory database — the shared-device shape the
/// defect was filed against — and pin each method's scoping plus the
/// #138 close-on-dispose contract for [watchPendingCount].
const _kUserA = 'user-a';
const _kUserB = 'user-b';

const _kOperation = AddToCollectionOperation(
  localId: 'local-1',
  platformGameId: 'pg-1',
  medium: 'Physical',
  quantity: 1,
);

void main() {
  late ServerDatabase db;
  late FixedClockService clock;
  late SyncQueueRepositoryImpl repoA;
  late SyncQueueRepositoryImpl repoB;

  setUp(() {
    db = inMemoryServerDatabase();
    clock = FixedClockService(DateTime.utc(2024, 1, 15, 10, 30));
    repoA = SyncQueueRepositoryImpl(db, clock, userId: _kUserA);
    repoB = SyncQueueRepositoryImpl(db, clock, userId: _kUserB);
  });

  tearDown(() async => db.close());

  Future<List<SyncQueueTableData>> rawRows() =>
      db.select(db.syncQueueTable).get();

  group('sync queue user scoping (#147)', () {
    test('enqueue stamps the scope user id on the row', () async {
      final entry = await repoA.enqueue(_kOperation);

      final row = (await rawRows()).single;
      expect(row.id, entry.id);
      expect(row.userId, _kUserA);
    });

    test('another user\'s scope reports zero pending and sees no entries; '
        'the departed user\'s rows stay intact in the table', () async {
      // The shared-device scenario from the issue: A queues offline...
      await repoA.enqueue(_kOperation);
      await repoA.enqueue(_kOperation);

      // ...A signs out, B signs in — a fresh repository over the SAME
      // table. B must see nothing (this is the read the drain worker
      // #121 will make).
      expect(await repoB.getPendingCount(), 0);
      expect(await repoB.getPendingEntries(), isEmpty);
      expect(await repoB.getAllEntries(), isEmpty);

      // The rows themselves are untouched — dormant, not discarded (D8).
      expect(await rawRows(), hasLength(2));
      expect((await rawRows()).map((r) => r.userId), everyElement(_kUserA));
    });

    test('the returning user\'s fresh scope sees their rows pending and '
        'drainable again', () async {
      final first = await repoA.enqueue(_kOperation);
      final second = await repoA.enqueue(_kOperation);

      // A signs out (instance disposed with the scope), B's session comes
      // and goes, then A signs back in: a NEW instance for the same user.
      await repoA.onDispose();
      final repoAReturned = SyncQueueRepositoryImpl(db, clock, userId: _kUserA);

      expect(await repoAReturned.getPendingCount(), 2);
      expect(
        (await repoAReturned.getPendingEntries()).map((e) => e.id),
        equals([first.id, second.id]),
        reason: 'FIFO order preserved across the dormant period',
      );
    });

    test('mark transitions cannot touch another user\'s entry, even with '
        'its id in hand', () async {
      final entry = await repoA.enqueue(_kOperation);

      await repoB.markInProgress(entry.id);
      await repoB.markCompleted(entry.id);
      await repoB.markFailed(entry.id, error: 'not yours');

      final row = (await rawRows()).single;
      expect(row.status, 'pending', reason: 'no cross-user transition');
      expect(row.retryCount, 0);
      expect(row.lastError, isNull);
      expect(row.lastAttemptAt, isNull);
    });

    test(
      'purgeCompleted removes only the current user\'s completed rows',
      () async {
        final a = await repoA.enqueue(_kOperation);
        final b = await repoB.enqueue(_kOperation);
        await repoA.markCompleted(a.id);
        await repoB.markCompleted(b.id);

        expect(await repoA.purgeCompleted(), 1);

        final remaining = (await rawRows()).single;
        expect(remaining.id, b.id);
        expect(remaining.userId, _kUserB);
      },
    );

    test('resetStaleInProgress recovers only the current user\'s stuck '
        'entries', () async {
      final a = await repoA.enqueue(_kOperation);
      final b = await repoB.enqueue(_kOperation);
      await repoA.markInProgress(a.id);
      await repoB.markInProgress(b.id);

      expect(await repoA.resetStaleInProgress(), 1);

      final rows = await rawRows();
      expect(
        rows.singleWhere((r) => r.id == a.id).status,
        'pending',
        reason: 'A\'s crash recovery resets A\'s entry',
      );
      expect(
        rows.singleWhere((r) => r.id == b.id).status,
        'inProgress',
        reason: 'B\'s in-flight entry is not A\'s to recover',
      );
    });

    test(
      'remapCollectionId rewrites only the current user\'s payloads',
      () async {
        await repoA.enqueue(_kOperation);
        await repoB.enqueue(_kOperation);

        final remapped = await repoA.remapCollectionId(
          oldCollectionId: 'local-1',
          newCollectionId: 'server-1',
        );

        expect(remapped, 1);
        final rows = await rawRows();
        final aPayload = rows.singleWhere((r) => r.userId == _kUserA).payload;
        final bPayload = rows.singleWhere((r) => r.userId == _kUserB).payload;
        expect(aPayload, contains('server-1'));
        expect(bPayload, contains('local-1'));
      },
    );

    test('watchPendingCount counts only the current user\'s outstanding '
        'work', () async {
      await repoA.enqueue(_kOperation);

      await expectLater(repoB.watchPendingCount().take(1), emits(0));
      await expectLater(repoA.watchPendingCount().take(1), emits(1));
    });
  });

  group('disposal (#135 / #138)', () {
    test('onDispose closes a live watchPendingCount stream without an '
        'error', () async {
      var done = false;
      Object? streamError;
      final sub = repoA.watchPendingCount().listen(
        (_) {},
        onError: (Object e) => streamError = e,
        onDone: () => done = true,
      );
      addTearDown(sub.cancel);
      await pumpEventQueue();
      expect(done, isFalse);

      await repoA.onDispose();
      await pumpEventQueue();

      expect(done, isTrue, reason: 'close, not error — the #135 contract');
      expect(streamError, isNull);
    });

    test('watchPendingCount after disposal returns an already-closed '
        'stream', () async {
      await repoA.onDispose();

      await expectLater(repoA.watchPendingCount(), emitsDone);
    });

    test('methods after disposal throw StateError', () async {
      await repoA.onDispose();

      await expectLater(repoA.enqueue(_kOperation), throwsStateError);
      await expectLater(repoA.getPendingEntries(), throwsStateError);
      await expectLater(repoA.getPendingCount(), throwsStateError);
      await expectLater(repoA.purgeCompleted(), throwsStateError);
    });

    test('onDispose is idempotent', () async {
      await repoA.onDispose();
      await expectLater(repoA.onDispose(), completes);
    });

    test('disposing one user\'s repository does not disturb another\'s '
        'live stream over the same table', () async {
      final events = <int>[];
      final sub = repoB.watchPendingCount().listen(events.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      await repoA.onDispose();
      await repoB.enqueue(_kOperation);
      await pumpEventQueue();

      expect(events.last, 1, reason: 'B\'s stream stays live and correct');
    });
  });

  group('raw-row visibility guard', () {
    test('a directly inserted row for another user is invisible through '
        'every read path', () async {
      await db
          .into(db.syncQueueTable)
          .insert(
            SyncQueueTableCompanion.insert(
              id: 'foreign-1',
              userId: _kUserB,
              payload: _kOperation.serialized,
              status: const Value('pending'),
              createdAt: DateTime.utc(2024, 1, 15, 10, 30),
            ),
          );

      expect(await repoA.getPendingEntries(), isEmpty);
      expect(await repoA.getAllEntries(), isEmpty);
      expect(await repoA.getPendingCount(), 0);
      await expectLater(repoA.watchPendingCount().take(1), emits(0));
    });
  });
}
