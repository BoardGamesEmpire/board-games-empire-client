import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';

import '../support/fixed_clock.dart';

/// The queue's half of recovering stuck ops (#190): the stream the
/// retry-or-discard screen reads, the retry and discard it offers, and the
/// retention that keeps completed history bounded.
void main() {
  final start = DateTime.utc(2026, 10, 17, 12);
  late ServerDatabase db;
  late FixedClockService clock;
  late SyncQueueRepositoryImpl repo;

  setUp(() {
    db = inMemoryServerDatabase();
    clock = FixedClockService(start);
    repo = SyncQueueRepositoryImpl(
      db,
      clock,
      userId: 'user-1',
      localNowUtc: clock.nowUtc,
    );
  });

  tearDown(() async => db.close());

  Future<SyncQueueEntry> enqueueAdd(String localId) => repo.enqueue(
    AddToCollectionOperation(
      localId: localId,
      platformGameId: 'pg-$localId',
      medium: 'Physical',
      quantity: 1,
    ),
  );

  Future<void> exhaust(String id) async {
    for (var i = 0; i < SyncQueueEntry.maxRetries; i++) {
      await repo.markFailed(id, error: 'timeout $i');
    }
  }

  Future<SyncQueueEntry?> read(String id) async {
    for (final entry in await repo.getAllEntries()) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  group('watchStuckEntries()', () {
    test('emits parked and exhausted entries in queue order, and nothing '
        'that can still be sent or is done', () async {
      final exhausted = await enqueueAdd('a');
      final parked = await enqueueAdd('b');
      final failedOnce = await enqueueAdd('c');
      await enqueueAdd('d');
      final completed = await enqueueAdd('e');
      await exhaust(exhausted.id);
      await repo.park(parked.id, error: 'rejected: 400');
      await repo.markFailed(failedOnce.id, error: 'timeout');
      await repo.markCompleted(completed.id);

      final stuck = await repo.watchStuckEntries().first;

      expect(stuck.map((e) => e.id), [exhausted.id, parked.id]);
    });

    test('re-emits when an entry gets stuck', () async {
      final entry = await enqueueAdd('a');
      final emissions = repo.watchStuckEntries().take(2).toList();
      await Future<void>.delayed(Duration.zero);

      await repo.park(entry.id, error: 'rejected: 400');

      final lists = await emissions.timeout(const Duration(seconds: 5));
      expect(lists.map((l) => l.map((e) => e.id).toList()), [
        <String>[],
        [entry.id],
      ]);
    });

    test('closes when the repository is disposed', () async {
      final done = repo.watchStuckEntries().drain<void>();
      await Future<void>.delayed(Duration.zero);

      await repo.onDispose();

      await expectLater(done.timeout(const Duration(seconds: 5)), completes);
    });
  });

  group('retry()', () {
    test('puts a parked entry back as new, keeping its error', () async {
      final entry = await enqueueAdd('a');
      expect(await repo.claim(entry.id), isTrue);
      await repo.park(entry.id, error: 'rejected: 400');

      expect(await repo.retry(entry.id), isTrue);

      final retried = (await read(entry.id))!;
      expect(retried.status, SyncStatus.pending);
      expect(retried.retryCount, 0);
      expect(retried.lastAttemptAt, isNull);
      expect(retried.lastError, 'rejected: 400');
      expect(await repo.getPendingEntries(), [
        isA<SyncQueueEntry>().having((e) => e.id, 'id', entry.id),
      ]);
      expect(await repo.getPendingCount(), 1);
      expect(await repo.watchStuckEntries().first, isEmpty);
    });

    test('lets an entry that ran out of retries be claimed at once', () async {
      final entry = await enqueueAdd('a');
      await exhaust(entry.id);

      expect(await repo.retry(entry.id), isTrue);

      expect(await repo.claim(entry.id), isTrue);
    });

    test('leaves an entry that is not stuck alone', () async {
      final pending = await enqueueAdd('a');
      final failedOnce = await enqueueAdd('b');
      await repo.markFailed(failedOnce.id, error: 'timeout');
      final completed = await enqueueAdd('c');
      await repo.markCompleted(completed.id);

      expect(await repo.retry(pending.id), isFalse);
      expect(await repo.retry(failedOnce.id), isFalse);
      expect(await repo.retry(completed.id), isFalse);
      expect(await repo.retry('nonexistent'), isFalse);

      expect((await read(failedOnce.id))!.retryCount, 1);
      expect((await read(completed.id))!.status, SyncStatus.completed);
    });

    test('of two retries of one entry, only the first reopens it', () async {
      final entry = await enqueueAdd('a');
      await repo.park(entry.id, error: 'rejected: 400');

      final results = await Future.wait([
        repo.retry(entry.id),
        repo.retry(entry.id),
      ]);

      expect(results.where((r) => r), hasLength(1));
    });
  });

  group('discard()', () {
    test('deletes an entry not yet completed', () async {
      final parked = await enqueueAdd('a');
      await repo.park(parked.id, error: 'rejected: 400');
      final pending = await enqueueAdd('b');

      expect(await repo.discard(parked.id), isTrue);
      expect(await repo.discard(pending.id), isTrue);

      expect(await repo.getAllEntries(), isEmpty);
    });

    test('leaves a completed entry for the purge', () async {
      final entry = await enqueueAdd('a');
      await repo.markCompleted(entry.id);

      expect(await repo.discard(entry.id), isFalse);
      expect(await repo.discard('nonexistent'), isFalse);

      expect((await read(entry.id))!.status, SyncStatus.completed);
    });

    test('drops the entry from the stuck stream', () async {
      final entry = await enqueueAdd('a');
      await repo.park(entry.id, error: 'rejected: 400');
      final emissions = repo.watchStuckEntries().take(2).toList();
      await Future<void>.delayed(Duration.zero);

      await repo.discard(entry.id);

      final lists = await emissions.timeout(const Duration(seconds: 5));
      expect(lists.last, isEmpty);
    });
  });

  group('discardStuck()', () {
    test('deletes a stuck entry, whether parked or exhausted', () async {
      final parked = await enqueueAdd('a');
      await repo.park(parked.id, error: 'rejected: 400');
      final exhausted = await enqueueAdd('b');
      await exhaust(exhausted.id);

      expect(await repo.discardStuck(parked.id), isTrue);
      expect(await repo.discardStuck(exhausted.id), isTrue);

      expect(await repo.getAllEntries(), isEmpty);
    });

    test('leaves an entry that is still being worked on, or done', () async {
      final pending = await enqueueAdd('a');
      final claimed = await enqueueAdd('b');
      await repo.claim(claimed.id);
      final retried = await enqueueAdd('c');
      await repo.park(retried.id, error: 'rejected: 400');
      await repo.retry(retried.id);
      final completed = await enqueueAdd('d');
      await repo.markCompleted(completed.id);

      for (final id in [pending.id, claimed.id, retried.id, completed.id]) {
        expect(await repo.discardStuck(id), isFalse, reason: id);
      }
      expect(await repo.discardStuck('nonexistent'), isFalse);

      expect(await repo.getAllEntries(), hasLength(4));
    });
  });

  group('getEntry()', () {
    test('returns the entry whatever its status', () async {
      final entry = await enqueueAdd('a');
      await repo.markCompleted(entry.id);

      final read = await repo.getEntry(entry.id);

      expect(read?.id, entry.id);
      expect(read?.status, SyncStatus.completed);
    });

    test("returns null for an unknown id or another user's entry", () async {
      final other = SyncQueueRepositoryImpl(
        db,
        clock,
        userId: 'user-2',
        localNowUtc: clock.nowUtc,
      );
      final theirs = await other.enqueue(
        const RemoveFromCollectionOperation(collectionId: 'col-1'),
      );

      expect(await repo.getEntry(theirs.id), isNull);
      expect(await repo.getEntry('nonexistent'), isNull);
    });
  });

  group('purgeCompleted(olderThan:)', () {
    const retention = Duration(hours: 24);

    Future<SyncQueueEntry> completeAt(String localId, DateTime at) async {
      clock.current = at;
      final entry = await enqueueAdd(localId);
      expect(await repo.claim(entry.id), isTrue);
      await repo.markCompleted(entry.id);
      return entry;
    }

    test('deletes completed entries last attempted before the cutoff, and '
        'keeps newer ones', () async {
      final old = await completeAt('a', start);
      final recent = await completeAt(
        'b',
        start.add(const Duration(hours: 12)),
      );
      clock.current = start.add(retention + const Duration(minutes: 1));

      expect(await repo.purgeCompleted(olderThan: retention), 1);

      expect(await read(old.id), isNull);
      expect(await read(recent.id), isNotNull);
    });

    test('never deletes an entry not yet completed, however old', () async {
      final stuck = await enqueueAdd('a');
      expect(await repo.claim(stuck.id), isTrue);
      await repo.park(stuck.id, error: 'rejected: 400');
      final failed = await enqueueAdd('b');
      await repo.markFailed(failed.id, error: 'timeout');
      final pending = await enqueueAdd('c');
      clock.current = start.add(retention * 30);

      expect(await repo.purgeCompleted(olderThan: retention), 0);

      expect(
        (await repo.getAllEntries()).map((e) => e.id),
        unorderedEquals([stuck.id, failed.id, pending.id]),
      );
    });

    test('keeps an entry stamped ahead of a clock set back', () async {
      final entry = await completeAt('a', start);
      clock.current = start.subtract(retention * 2);

      expect(await repo.purgeCompleted(olderThan: retention), 0);

      expect(await read(entry.id), isNotNull);
    });

    // A completed entry's last attempt is the claim that delivered it, which
    // is what the cutoff measures (#190). Completing it must not move that.
    test('measures from the delivering claim: completing leaves '
        'lastAttemptAt alone', () async {
      final entry = await enqueueAdd('a');
      expect(await repo.claim(entry.id), isTrue);
      clock.current = start.add(const Duration(minutes: 1));

      await repo.markCompleted(entry.id);

      expect((await read(entry.id))!.lastAttemptAt, start);
    });
  });
}
