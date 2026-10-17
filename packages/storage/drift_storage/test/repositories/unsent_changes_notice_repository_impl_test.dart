import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';
import 'package:drift_storage/src/repositories/unsent_changes_notice_repository_impl.dart';

import '../support/fixed_clock.dart';

/// #142: whose unsent changes the sign-in screen mentions, over the
/// per-server database the sync queue lives in. The queue rows are written
/// through the real per-user repositories, the way sessions write them.
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
  late UnsentChangesNoticeRepositoryImpl notice;

  setUp(() {
    db = inMemoryServerDatabase();
    clock = FixedClockService(DateTime.utc(2024, 1, 15, 10, 30));
    notice = UnsentChangesNoticeRepositoryImpl(db);
  });

  tearDown(() async => db.close());

  SyncQueueRepositoryImpl queueOf(String userId) => SyncQueueRepositoryImpl(
    db,
    clock,
    userId: userId,
    localNowUtc: clock.nowUtc,
  );

  group('UnsentChangesNoticeRepositoryImpl (#142)', () {
    test('counts nothing before any session has started', () async {
      await queueOf(_kUserA).enqueue(_kOperation);

      expect(await notice.unsentChangesCount(), 0);
    });

    test("counts the started session's user: pending and parked entries, "
        'never completed ones', () async {
      final queue = queueOf(_kUserA);
      await queue.enqueue(_kOperation);
      final parked = await queue.enqueue(_kOperation);
      for (var i = 0; i < SyncQueueEntry.maxRetries; i++) {
        await queue.markFailed(parked.id, error: 'rejected');
      }
      final sent = await queue.enqueue(_kOperation);
      await queue.markCompleted(sent.id);

      await notice.recordSessionStarted(_kUserA);

      expect(await notice.unsentChangesCount(), 2);
    });

    test("a deliberate sign-out stops the count and leaves the user's rows "
        'alone', () async {
      await queueOf(_kUserA).enqueue(_kOperation);
      await notice.recordSessionStarted(_kUserA);

      await notice.recordSignedOut(_kUserA);

      expect(await notice.unsentChangesCount(), 0);
      expect(await queueOf(_kUserA).getOutstandingEntries(), hasLength(1));
    });

    test('a session that ends any other way leaves the user counted, as at '
        'the next launch', () async {
      await queueOf(_kUserA).enqueue(_kOperation);
      await notice.recordSessionStarted(_kUserA);

      // Nothing is recorded for a lost session; reading again over the
      // same file is what the sign-in screen does after a restart.
      final afterRestart = UnsentChangesNoticeRepositoryImpl(db);

      expect(await afterRestart.unsentChangesCount(), 1);
    });

    // A left changes behind; then B used the device.
    group('on a shared device', () {
      test("a later user's lost session is the one the count speaks for — "
          'their sign-in is the one that sends what it counts', () async {
        await queueOf(_kUserA).enqueue(_kOperation);
        await notice.recordSessionStarted(_kUserA);

        await notice.recordSessionStarted(_kUserB);
        await queueOf(_kUserB).enqueue(_kOperation);
        await queueOf(_kUserB).enqueue(_kOperation);

        expect(await notice.unsentChangesCount(), 2);
      });

      test("a later user's deliberate sign-out brings back the changes the "
          'earlier user left', () async {
        await queueOf(_kUserA).enqueue(_kOperation);
        await notice.recordSessionStarted(_kUserA);
        await notice.recordSessionStarted(_kUserB);
        await queueOf(_kUserB).enqueue(_kOperation);
        await queueOf(_kUserB).enqueue(_kOperation);

        await notice.recordSignedOut(_kUserB);

        expect(await notice.unsentChangesCount(), 1);
      });

      test("a later user with nothing waiting doesn't hide the earlier "
          "user's changes", () async {
        await queueOf(_kUserA).enqueue(_kOperation);
        await notice.recordSessionStarted(_kUserA);

        await notice.recordSessionStarted(_kUserB);

        expect(await notice.unsentChangesCount(), 1);
      });

      test(
        'the earlier user coming back makes them the latest again',
        () async {
          await queueOf(_kUserA).enqueue(_kOperation);
          await notice.recordSessionStarted(_kUserA);
          await notice.recordSessionStarted(_kUserB);
          await queueOf(_kUserB).enqueue(_kOperation);
          await queueOf(_kUserB).enqueue(_kOperation);

          await notice.recordSessionStarted(_kUserA);

          expect(await notice.unsentChangesCount(), 1);
        },
      );
    });
  });
}
