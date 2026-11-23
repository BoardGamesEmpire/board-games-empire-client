import 'package:drift/native.dart' show NativeDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_collection_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixed_clock.dart';

const _kUserId = 'user-abc';
const _kOtherUserId = 'user-xyz';

/// A collection pass that completes records it, so a later session on this
/// device can trust the cache it confirmed (#771). The row is per user in
/// the server's database, and it outlives the session that wrote it.
void main() {
  late ServerDatabase db;
  late FixedClockService clock;

  setUp(() {
    db = ServerDatabase(NativeDatabase.memory());
    clock = FixedClockService(DateTime.utc(2026, 11, 22, 12));
  });

  tearDown(() async => db.close());

  GameCollectionRepositoryImpl repositoryFor(String userId) =>
      GameCollectionRepositoryImpl(
        db: db,
        syncQueue: SyncQueueRepositoryImpl(db, clock, userId: userId),
        currentUserId: userId,
        clock: clock,
      );

  Future<List<CollectionRefreshMarkersTableData>> markers() =>
      db.select(db.collectionRefreshMarkersTable).get();

  test('a user with no marker reads false', () async {
    expect(await repositoryFor(_kUserId).isRefreshConfirmed(), isFalse);
  });

  test(
    'recordRefreshConfirmed then isRefreshConfirmed is true for that user '
    'only',
    () async {
      final repository = repositoryFor(_kUserId);

      await repository.recordRefreshConfirmed();

      expect(await repository.isRefreshConfirmed(), isTrue);
      expect(await markers(), [
        CollectionRefreshMarkersTableData(
          userId: _kUserId,
          confirmedAt: clock.current,
        ),
      ]);
    },
  );

  test('another user on the same database reads false', () async {
    await repositoryFor(_kUserId).recordRefreshConfirmed();

    expect(await repositoryFor(_kOtherUserId).isRefreshConfirmed(), isFalse);
  });

  test('a later session for the same user reads it', () async {
    // The marker is not cleared with the session: a sign-out disposes the
    // repository with its scope, and signing back in builds a new one over
    // the same database.
    final first = repositoryFor(_kUserId);
    await first.recordRefreshConfirmed();
    await first.onDispose();

    expect(await repositoryFor(_kUserId).isRefreshConfirmed(), isTrue);
  });

  test('a second record moves confirmed_at rather than adding a row', () async {
    final repository = repositoryFor(_kUserId);
    await repository.recordRefreshConfirmed();
    clock.current = DateTime.utc(2026, 11, 23, 8);

    await repository.recordRefreshConfirmed();

    expect(await markers(), [
      CollectionRefreshMarkersTableData(
        userId: _kUserId,
        confirmedAt: DateTime.utc(2026, 11, 23, 8),
      ),
    ]);
  });

  test('both throw StateError after disposal', () async {
    final repository = repositoryFor(_kUserId);
    await repository.onDispose();

    await expectLater(repository.isRefreshConfirmed(), throwsStateError);
    await expectLater(repository.recordRefreshConfirmed(), throwsStateError);
    expect(await markers(), isEmpty);
  });
}
