import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_collection_repository_impl.dart';

class MockSyncQueue extends Mock implements SyncQueueRepository {}

// ── Fixtures ─────────────────────────────────────────────────────────────────

const _kUserId = 'user-abc';
const _kPlatformGameId = 'pg-1';
const _kMedium = GameMedium.physical;

Future<void> _seedPlatformGame(
  ServerDatabase db, {
  String id = _kPlatformGameId,
  String gameId = 'game-1',
}) async {
  final now = DateTime.now().toUtc();
  await db
      .into(db.gamesTable)
      .insertOnConflictUpdate(
        GamesTableCompanion.insert(
          id: gameId,
          title: 'Test Game',
          createdAt: now,
          updatedAt: now,
        ),
      );
  await db
      .into(db.platformGamesTable)
      .insert(
        PlatformGamesTableCompanion.insert(
          id: id,
          gameId: gameId,
          platformId: 'plat-1',
          platformName: 'Tabletop',
          createdAt: now,
          updatedAt: now,
        ),
      );
}

/// Default stubs for [MockSyncQueue]. Extracted so the post-`reset`
/// re-stub paths can share the same baseline.
void _stubMockSyncDefaults(MockSyncQueue mockSync) {
  when(() => mockSync.enqueue(any())).thenAnswer(
    (_) async => SyncQueueEntry(
      id: 'sq-stub',
      payload: '{}',
      createdAt: DateTime.now().toUtc(),
    ),
  );
  when(() => mockSync.markCompleted(any())).thenAnswer((_) async {});
  when(
    () => mockSync.remapCollectionId(
      oldCollectionId: any(named: 'oldCollectionId'),
      newCollectionId: any(named: 'newCollectionId'),
    ),
  ).thenAnswer((_) async => 0);
}

// ── Tests ──────────────────────────────────────────────────────────────────────

void main() {
  setUpAll(() {
    registerFallbackValue(
      const AddToCollectionOperation(
        localId: '',
        platformGameId: '',
        medium: '',
        quantity: 0,
      ),
    );
    registerFallbackValue(const UpdateCollectionOperation(collectionId: ''));
    registerFallbackValue(
      const RemoveFromCollectionOperation(collectionId: ''),
    );
  });

  late ServerDatabase db;
  late MockSyncQueue mockSync;
  late GameCollectionRepositoryImpl repo;

  setUp(() async {
    db = ServerDatabase.memory();
    mockSync = MockSyncQueue();

    _stubMockSyncDefaults(mockSync);

    repo = GameCollectionRepositoryImpl(
      db: db,
      syncQueue: mockSync,
      currentUserId: _kUserId,
    );

    await _seedPlatformGame(db);
  });

  tearDown(() async => db.close());

  group('GameCollectionRepositoryImpl', () {
    group('addToCollection() — fresh insert path', () {
      test('creates entry with isDirty and isLocalOnly true', () async {
        final entry = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );

        expect(entry.isDirty, isTrue);
        expect(entry.isLocalOnly, isTrue);
        expect(entry.userId, _kUserId);
        expect(entry.medium, _kMedium);
        expect(entry.quantity, 1);
        expect(entry.deletedAt, isNull);
      });

      test('enqueues AddToCollectionOperation', () async {
        await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );

        verify(
          () => mockSync.enqueue(any(that: isA<AddToCollectionOperation>())),
        ).called(1);
      });

      test('stores optional fields', () async {
        final entry = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
          rating: 8,
          comment: 'Great game',
        );

        expect(entry.rating, 8);
        expect(entry.comment, 'Great game');
      });
    });

    group('addToCollection() — duplicate triplet', () {
      test(
        'resurrects a tombstoned row (clears deletedAt, keeps id, overwrites fields)',
        () async {
          final first = await repo.addToCollection(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
            rating: 5,
          );
          await repo.removeFromCollection(first.id);

          // Sanity: getCollectionEntry must hide the tombstone.
          expect(
            await repo.getCollectionEntry(
              platformGameId: _kPlatformGameId,
              medium: _kMedium,
            ),
            isNull,
          );

          final second = await repo.addToCollection(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
            quantity: 1,
            rating: 9,
          );

          expect(second.id, equals(first.id));
          expect(second.deletedAt, isNull);
          expect(second.rating, equals(9));
          expect(second.quantity, equals(1));
          expect(second.isDirty, isTrue);
          expect(second.isLocalOnly, isTrue);

          // The collection now shows exactly one live entry.
          final collection = await repo.getCollection();
          expect(collection, hasLength(1));
          expect(collection.single.id, equals(first.id));
        },
      );

      test('increments quantity on a live duplicate', () async {
        final first = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );
        expect(first.quantity, equals(1));

        final second = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
          quantity: 2,
        );

        expect(second.id, equals(first.id));
        expect(second.quantity, equals(3));

        // Still one row.
        expect(await repo.getCollection(), hasLength(1));
      });

      test(
        'increment preserves existing rating/comment when caller omits them',
        () async {
          final first = await repo.addToCollection(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
            rating: 7,
            comment: 'good',
          );

          final second = await repo.addToCollection(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
          );

          expect(second.id, equals(first.id));
          expect(second.rating, equals(7));
          expect(second.comment, equals('good'));
        },
      );

      test(
        'resurrects the MOST RECENT tombstone when multiple coexist for the triplet',
        () async {
          final now = DateTime.now().toUtc();
          final older = now.subtract(const Duration(hours: 1));

          await db
              .into(db.gameCollectionsTable)
              .insert(
                GameCollectionsTableCompanion.insert(
                  id: 'old-tomb',
                  userId: _kUserId,
                  platformGameId: _kPlatformGameId,
                  medium: 'Physical',
                  quantity: const Value(2),
                  rating: const Value(5),
                  deletedAt: Value(older),
                  isDirty: const Value(true),
                  createdAt: older,
                  updatedAt: older,
                ),
              );
          await db
              .into(db.gameCollectionsTable)
              .insert(
                GameCollectionsTableCompanion.insert(
                  id: 'new-tomb',
                  userId: _kUserId,
                  platformGameId: _kPlatformGameId,
                  medium: 'Physical',
                  quantity: const Value(3),
                  rating: const Value(8),
                  deletedAt: Value(now),
                  isDirty: const Value(true),
                  createdAt: now,
                  updatedAt: now,
                ),
              );

          expect(await db.select(db.gameCollectionsTable).get(), hasLength(2));

          final entry = await repo.addToCollection(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
            quantity: 1,
            rating: 9,
          );

          expect(entry.id, equals('new-tomb'));
          expect(entry.deletedAt, isNull);
          expect(entry.rating, equals(9));
          expect(entry.quantity, equals(1));

          final old = await (db.select(
            db.gameCollectionsTable,
          )..where((t) => t.id.equals('old-tomb'))).getSingle();
          expect(old.deletedAt, isNotNull);
          expect(old.rating, equals(5));
        },
      );

      test('rowId tiebreaker resurrects the LATER-INSERTED tombstone when two '
          'share the same updatedAt', () async {
        // The same-microsecond race: an addToCollection →
        // removeFromCollection burst on a fast machine can land
        // two tombstones at identical updatedAt.
        //
        // The pre-existing "MOST RECENT tombstone" test uses
        // distinct updatedAt values one hour apart, so it never
        // exercises the tiebreaker. This test pins identical
        // updatedAt values to ISOLATE the rowId DESC tail term.
        final t = DateTime.now().toUtc();

        await db
            .into(db.gameCollectionsTable)
            .insert(
              GameCollectionsTableCompanion.insert(
                id: 'tomb-first',
                userId: _kUserId,
                platformGameId: _kPlatformGameId,
                medium: 'Physical',
                quantity: const Value(1),
                rating: const Value(3),
                deletedAt: Value(t),
                isDirty: const Value(true),
                createdAt: t,
                updatedAt: t,
              ),
            );
        await db
            .into(db.gameCollectionsTable)
            .insert(
              GameCollectionsTableCompanion.insert(
                id: 'tomb-second',
                userId: _kUserId,
                platformGameId: _kPlatformGameId,
                medium: 'Physical',
                quantity: const Value(1),
                rating: const Value(7),
                deletedAt: Value(t),
                isDirty: const Value(true),
                createdAt: t,
                updatedAt: t,
              ),
            );

        final entry = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
          quantity: 1,
          rating: 9,
        );

        expect(entry.id, equals('tomb-second'));
        expect(entry.rating, equals(9));
        // tomb-first is left untouched.
        final first = await (db.select(
          db.gameCollectionsTable,
        )..where((t) => t.id.equals('tomb-first'))).getSingle();
        expect(first.deletedAt, isNotNull);
        expect(first.rating, equals(3));
      });

      test('resurrection preserves play history and prior rating/comment '
          'when caller omits them', () async {
        // The design call, documented in
        // `GameCollectionRepository.addToCollection` and in the
        // repo impl's "Resurrection preserves play history"
        // section: removing a collection entry means "I don't
        // own this anymore", not "I never played this." Per-game
        // metadata — play history AND opinion fields — survives
        // the remove → re-add cycle. rating/comment follow the
        // updateCollectionEntry null-handling: null/omitted means
        // leave-unchanged, so they also survive when the caller
        // doesn't supply new values
        //
        // This test pins ALL the preserved columns at once, so a
        // future regression that resets any of them — playCount,
        // playAgain, favorite, lastPlayed, rating, comment —
        // fails here loudly with a clear name.
        final first = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
          quantity: 2,
          rating: 8,
          comment: 'great party game',
        );

        // Simulate play history accumulated over the entry's
        // lifetime: 5 plays, favorited, marked "would play
        // again", last played on a known date.
        final lastPlayedTimestamp = DateTime.utc(2025, 6, 1);
        await repo.updateCollectionEntry(
          id: first.id,
          playCount: 5,
          playAgain: true,
          favorite: true,
          lastPlayed: lastPlayedTimestamp,
        );

        // Tombstone, then re-add WITHOUT supplying any optional
        // fields — only the required triplet identity and a
        // fresh quantity.
        await repo.removeFromCollection(first.id);
        final second = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
          quantity: 1,
          // rating + comment intentionally omitted.
        );

        // Same row resurrected, lifecycle flags reset.
        expect(second.id, equals(first.id));
        expect(second.deletedAt, isNull);
        expect(second.isDirty, isTrue);
        expect(second.isLocalOnly, isTrue);

        // Quantity uses the caller-supplied value — a fresh
        // ownership declaration, NOT a sum of prior + new.
        expect(second.quantity, equals(1));

        // Play history preserved: the resurrection write must
        // not touch these columns.
        expect(second.playCount, equals(5));
        expect(second.playAgain, isTrue);
        expect(second.favorite, isTrue);
        expect(second.lastPlayed, equals(lastPlayedTimestamp));

        // Rating + comment preserved: caller didn't supply new
        // values, so Value.absent() guards leave the prior
        // values alone — symmetric with the live-row update
        // branch's null-handling.
        expect(second.rating, equals(8));
        expect(second.comment, equals('great party game'));

        // The collection presents exactly one live entry under
        // the resurrected id.
        final collection = await repo.getCollection();
        expect(collection, hasLength(1));
        expect(collection.single.id, equals(first.id));
      });
    });

    group('updateCollectionEntry()', () {
      test('updates specified fields only', () async {
        final original = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );

        final updated = await repo.updateCollectionEntry(
          id: original.id,
          rating: 9,
          favorite: true,
        );

        expect(updated.rating, 9);
        expect(updated.favorite, isTrue);
        expect(updated.isDirty, isTrue);
        expect(updated.medium, original.medium); // unchanged
      });

      test('enqueues exactly one UpdateCollectionOperation', () async {
        final entry = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );

        await repo.updateCollectionEntry(id: entry.id, playCount: 3);

        verify(
          () => mockSync.enqueue(any(that: isA<UpdateCollectionOperation>())),
        ).called(1);
      });

      test(
        'throws StateError when entry belongs to a different user',
        () async {
          await _seedPlatformGame(db, id: 'pg-other');
          final now = DateTime.now().toUtc();
          await db
              .into(db.gameCollectionsTable)
              .insert(
                GameCollectionsTableCompanion.insert(
                  id: 'other-entry',
                  userId: 'other-user',
                  platformGameId: 'pg-other',
                  medium: 'Physical',
                  quantity: const Value(5),
                  rating: const Value(7),
                  createdAt: now,
                  updatedAt: now,
                ),
              );

          await expectLater(
            () => repo.updateCollectionEntry(id: 'other-entry', rating: 1),
            throwsStateError,
          );

          final row = await (db.select(
            db.gameCollectionsTable,
          )..where((t) => t.id.equals('other-entry'))).getSingle();
          expect(row.rating, equals(7));
          expect(row.userId, equals('other-user'));
        },
      );

      test(
        'does NOT enqueue a sync op when the entry is not found (transaction rolled back)',
        () async {
          await expectLater(
            () => repo.updateCollectionEntry(id: 'nonexistent', rating: 1),
            throwsStateError,
          );
          verifyNever(() => mockSync.enqueue(any()));
        },
      );

      test('throws StateError when the target entry is tombstoned', () async {
        final entry = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );
        await repo.removeFromCollection(entry.id);

        await expectLater(
          () => repo.updateCollectionEntry(id: entry.id, rating: 10),
          throwsStateError,
        );

        verifyNever(
          () => mockSync.enqueue(any(that: isA<UpdateCollectionOperation>())),
        );
      });
    });

    group('quantity validation', () {
      // The validation runs BEFORE the transaction opens, so all of
      // these assertions also verify that no DB row was written and
      // no sync op was enqueued.

      test('addToCollection throws ArgumentError on quantity == 0', () async {
        await expectLater(
          () => repo.addToCollection(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
            quantity: 0,
          ),
          throwsA(isA<ArgumentError>()),
        );

        // No row in cache, no enqueue.
        expect(await repo.getCollection(), isEmpty);
        verifyNever(() => mockSync.enqueue(any()));
      });

      test(
        'addToCollection throws ArgumentError on negative quantity',
        () async {
          await expectLater(
            () => repo.addToCollection(
              platformGameId: _kPlatformGameId,
              medium: _kMedium,
              quantity: -3,
            ),
            throwsA(isA<ArgumentError>()),
          );

          expect(await repo.getCollection(), isEmpty);
          verifyNever(() => mockSync.enqueue(any()));
        },
      );

      test(
        'updateCollectionEntry throws ArgumentError on quantity == 0',
        () async {
          final entry = await repo.addToCollection(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
            quantity: 5,
          );
          // Reset the mock so we can verify NO further enqueues fire
          // from the failed update.
          reset(mockSync);
          _stubMockSyncDefaults(mockSync);

          await expectLater(
            () => repo.updateCollectionEntry(id: entry.id, quantity: 0),
            throwsA(isA<ArgumentError>()),
          );

          verifyNever(() => mockSync.enqueue(any()));
          // Underlying quantity unchanged.
          final row = (await repo.getCollection()).single;
          expect(row.quantity, equals(5));
        },
      );

      test(
        'updateCollectionEntry throws ArgumentError on negative quantity',
        () async {
          final entry = await repo.addToCollection(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
            quantity: 5,
          );
          reset(mockSync);
          _stubMockSyncDefaults(mockSync);

          await expectLater(
            () => repo.updateCollectionEntry(id: entry.id, quantity: -2),
            throwsA(isA<ArgumentError>()),
          );

          verifyNever(() => mockSync.enqueue(any()));
          final row = (await repo.getCollection()).single;
          expect(row.quantity, equals(5));
        },
      );

      test(
        'updateCollectionEntry accepts null quantity (leave-unchanged semantic)',
        () async {
          // Sanity: the validation only fires on non-null negatives.
          // null means "don't touch this field" by API contract, which
          // is the path callers use to update other fields without
          // affecting quantity.
          final entry = await repo.addToCollection(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
            quantity: 5,
          );

          final updated = await repo.updateCollectionEntry(
            id: entry.id,
            rating: 9,
          );

          expect(updated.quantity, equals(5));
          expect(updated.rating, equals(9));
        },
      );
    });

    group('removeFromCollection()', () {
      test('tombstones entry by setting deletedAt', () async {
        final entry = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );

        await repo.removeFromCollection(entry.id);

        expect(
          await repo.getCollectionEntry(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
          ),
          isNull,
        );

        final row = await (db.select(
          db.gameCollectionsTable,
        )..where((t) => t.id.equals(entry.id))).getSingleOrNull();
        expect(row, isNotNull);
        expect(row!.deletedAt, isNotNull);
        expect(row.isDirty, isTrue);
      });

      test('enqueues RemoveFromCollectionOperation', () async {
        final entry = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );

        await repo.removeFromCollection(entry.id);

        verify(
          () =>
              mockSync.enqueue(any(that: isA<RemoveFromCollectionOperation>())),
        ).called(1);
      });

      test(
        'throws StateError when entry belongs to a different user',
        () async {
          await _seedPlatformGame(db, id: 'pg-other');
          final now = DateTime.now().toUtc();
          await db
              .into(db.gameCollectionsTable)
              .insert(
                GameCollectionsTableCompanion.insert(
                  id: 'other-entry',
                  userId: 'other-user',
                  platformGameId: 'pg-other',
                  medium: 'Physical',
                  quantity: const Value(3),
                  createdAt: now,
                  updatedAt: now,
                ),
              );

          await expectLater(
            () => repo.removeFromCollection('other-entry'),
            throwsStateError,
          );

          final row = await (db.select(
            db.gameCollectionsTable,
          )..where((t) => t.id.equals('other-entry'))).getSingle();
          expect(row.deletedAt, isNull);
        },
      );

      test('is idempotent on an already-tombstoned entry '
          '(no double-enqueue, no DB write)', () async {
        final entry = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );
        await repo.removeFromCollection(entry.id);

        final firstTombstone = (await (db.select(
          db.gameCollectionsTable,
        )..where((t) => t.id.equals(entry.id))).getSingle()).deletedAt;
        expect(firstTombstone, isNotNull);

        await repo.removeFromCollection(entry.id);

        final secondTombstone = (await (db.select(
          db.gameCollectionsTable,
        )..where((t) => t.id.equals(entry.id))).getSingle()).deletedAt;
        expect(secondTombstone, equals(firstTombstone));

        verify(
          () =>
              mockSync.enqueue(any(that: isA<RemoveFromCollectionOperation>())),
        ).called(1);
      });
    });

    group('transaction atomicity', () {
      test(
        'addToCollection rolls back the local insert when enqueue throws',
        () async {
          when(
            () => mockSync.enqueue(any()),
          ).thenThrow(Exception('queue offline'));

          await expectLater(
            () => repo.addToCollection(
              platformGameId: _kPlatformGameId,
              medium: _kMedium,
            ),
            throwsException,
          );

          expect(await repo.getCollection(), isEmpty);
          final rawRows = await db.select(db.gameCollectionsTable).get();
          expect(rawRows, isEmpty);
        },
      );

      test(
        'removeFromCollection rolls back the tombstone when enqueue throws',
        () async {
          final entry = await repo.addToCollection(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
          );

          when(
            () => mockSync.enqueue(any()),
          ).thenThrow(Exception('queue offline'));

          await expectLater(
            () => repo.removeFromCollection(entry.id),
            throwsException,
          );

          final row = await (db.select(
            db.gameCollectionsTable,
          )..where((t) => t.id.equals(entry.id))).getSingle();
          expect(row.deletedAt, isNull);
        },
      );
    });

    group('reconcileFromServer()', () {
      test('clears isDirty and isLocalOnly flags', () async {
        final local = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );

        final serverEntry = local.copyWith(
          id: 'server-confirmed-id',
          isDirty: false,
          isLocalOnly: false,
        );

        await repo.reconcileFromServer(serverEntry);

        final result = await repo.getCollectionEntry(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );
        expect(result, isNotNull);
        expect(result!.id, equals('server-confirmed-id'));
        expect(result.isDirty, isFalse);
        expect(result.isLocalOnly, isFalse);

        expect(
          await (db.select(
            db.gameCollectionsTable,
          )..where((t) => t.id.equals(local.id))).getSingleOrNull(),
          isNull,
        );
      });

      test('marks the matching sync-queue entry completed when '
          '[completedSyncQueueId] is provided', () async {
        final local = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );

        final serverEntry = local.copyWith(
          id: 'server-confirmed-id',
          isDirty: false,
          isLocalOnly: false,
        );
        await repo.reconcileFromServer(
          serverEntry,
          completedSyncQueueId: 'sq-add-1',
        );

        verify(() => mockSync.markCompleted('sq-add-1')).called(1);
      });

      test(
        'does not touch the sync queue when [completedSyncQueueId] is omitted',
        () async {
          // The full-resync path (server-driven reconciliation that
          // didn't originate from a local mutation) must not invoke
          // markCompleted with a stale or guessed id.
          final local = await repo.addToCollection(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
          );

          final serverEntry = local.copyWith(
            id: 'server-confirmed-id',
            isDirty: false,
            isLocalOnly: false,
          );
          await repo.reconcileFromServer(serverEntry);

          verifyNever(() => mockSync.markCompleted(any()));
        },
      );

      test(
        'does not throw when multiple tombstones coexist for the triplet '
        '(uses the shared _findCanonicalRow ordered+limited lookup)',
        () async {
          final now = DateTime.now().toUtc();
          final older = now.subtract(const Duration(hours: 2));
          final mid = now.subtract(const Duration(hours: 1));

          await db
              .into(db.gameCollectionsTable)
              .insert(
                GameCollectionsTableCompanion.insert(
                  id: 'old-tomb',
                  userId: _kUserId,
                  platformGameId: _kPlatformGameId,
                  medium: 'Physical',
                  quantity: const Value(1),
                  deletedAt: Value(older),
                  createdAt: older,
                  updatedAt: older,
                ),
              );
          await db
              .into(db.gameCollectionsTable)
              .insert(
                GameCollectionsTableCompanion.insert(
                  id: 'new-tomb',
                  userId: _kUserId,
                  platformGameId: _kPlatformGameId,
                  medium: 'Physical',
                  quantity: const Value(2),
                  deletedAt: Value(mid),
                  createdAt: mid,
                  updatedAt: mid,
                ),
              );

          final serverEntry = GameCollection(
            id: 'server-canonical',
            userId: _kUserId,
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
            quantity: 3,
            isDirty: false,
            isLocalOnly: false,
            createdAt: now,
            updatedAt: now,
          );

          await repo.reconcileFromServer(serverEntry);

          final live = await repo.getCollectionEntry(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
          );
          expect(live, isNotNull);
          expect(live!.id, equals('server-canonical'));
          expect(live.quantity, equals(3));
          expect(live.isDirty, isFalse);
          expect(live.isLocalOnly, isFalse);
        },
      );

      group('current-user boundary', () {
        test('throws StateError when serverEntry.userId differs from the '
            'repository scope', () async {
          final now = DateTime.now().toUtc();
          final foreign = GameCollection(
            id: 'foreign-id',
            userId: 'someone-else',
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
            quantity: 1,
            isDirty: false,
            isLocalOnly: false,
            createdAt: now,
            updatedAt: now,
          );

          await expectLater(
            () => repo.reconcileFromServer(foreign),
            throwsStateError,
          );
        });

        test(
          'does NOT write a row or touch the sync queue when boundary throws',
          () async {
            final now = DateTime.now().toUtc();
            final foreign = GameCollection(
              id: 'foreign-id',
              userId: 'someone-else',
              platformGameId: _kPlatformGameId,
              medium: _kMedium,
              quantity: 1,
              isDirty: false,
              isLocalOnly: false,
              createdAt: now,
              updatedAt: now,
            );

            await expectLater(
              () => repo.reconcileFromServer(
                foreign,
                completedSyncQueueId: 'sq-misrouted',
              ),
              throwsStateError,
            );

            expect(await db.select(db.gameCollectionsTable).get(), isEmpty);
            verifyNever(() => mockSync.markCompleted(any()));
            verifyNever(
              () => mockSync.remapCollectionId(
                oldCollectionId: any(named: 'oldCollectionId'),
                newCollectionId: any(named: 'newCollectionId'),
              ),
            );
          },
        );
      });

      group('tombstone confirmation', () {
        test(
          'physically deletes the local row when serverEntry.deletedAt is set',
          () async {
            // Removal flow: user calls removeFromCollection →
            // local row is tombstoned (deletedAt set) and a
            // RemoveOp is queued. The worker syncs the op, the
            // server confirms by sending back the entry with
            // deletedAt non-null. reconcileFromServer must
            // PHYSICALLY delete the local row at that point,
            // not just store another tombstone.
            final local = await repo.addToCollection(
              platformGameId: _kPlatformGameId,
              medium: _kMedium,
            );
            await repo.removeFromCollection(local.id);

            // Tombstone exists locally.
            expect(
              await (db.select(
                db.gameCollectionsTable,
              )..where((t) => t.id.equals(local.id))).getSingleOrNull(),
              isNotNull,
            );

            final now = DateTime.now().toUtc();
            final serverTombstone = local.copyWith(
              isDirty: false,
              isLocalOnly: false,
              deletedAt: now,
              updatedAt: now,
            );

            await repo.reconcileFromServer(
              serverTombstone,
              completedSyncQueueId: 'sq-remove-1',
            );

            // Local row gone (not just re-tombstoned).
            expect(
              await (db.select(
                db.gameCollectionsTable,
              )..where((t) => t.id.equals(local.id))).getSingleOrNull(),
              isNull,
            );
            // No live entry resurfaces.
            expect(
              await repo.getCollectionEntry(
                platformGameId: _kPlatformGameId,
                medium: _kMedium,
              ),
              isNull,
            );
            // Queue closure still happens.
            verify(() => mockSync.markCompleted('sq-remove-1')).called(1);
          },
        );

        test(
          'deletes EVERY row for the triplet on tombstone confirmation',
          () async {
            // Multi-tombstone case: the partial unique index only
            // constrains live rows, so a triplet can accumulate
            // several tombstones over time. A server-confirmed
            // removal should cleanly purge all of them so the
            // cache doesn't keep growing with stale ghosts.
            final now = DateTime.now().toUtc();
            final older = now.subtract(const Duration(hours: 2));
            final mid = now.subtract(const Duration(hours: 1));

            await db
                .into(db.gameCollectionsTable)
                .insert(
                  GameCollectionsTableCompanion.insert(
                    id: 'old-tomb',
                    userId: _kUserId,
                    platformGameId: _kPlatformGameId,
                    medium: 'Physical',
                    quantity: const Value(1),
                    deletedAt: Value(older),
                    createdAt: older,
                    updatedAt: older,
                  ),
                );
            await db
                .into(db.gameCollectionsTable)
                .insert(
                  GameCollectionsTableCompanion.insert(
                    id: 'new-tomb',
                    userId: _kUserId,
                    platformGameId: _kPlatformGameId,
                    medium: 'Physical',
                    quantity: const Value(2),
                    deletedAt: Value(mid),
                    createdAt: mid,
                    updatedAt: mid,
                  ),
                );

            expect(
              await db.select(db.gameCollectionsTable).get(),
              hasLength(2),
            );

            final serverTombstone = GameCollection(
              id: 'server-tomb-id',
              userId: _kUserId,
              platformGameId: _kPlatformGameId,
              medium: _kMedium,
              quantity: 1,
              isDirty: false,
              isLocalOnly: false,
              deletedAt: now,
              createdAt: now,
              updatedAt: now,
            );

            await repo.reconcileFromServer(serverTombstone);

            // Both tombstones gone.
            expect(await db.select(db.gameCollectionsTable).get(), isEmpty);
          },
        );

        test(
          'does NOT upsert a tombstone row even when no local row exists',
          () async {
            // Server-driven tombstone confirmation for a triplet
            // that the local cache never saw (e.g. another client
            // added and removed before this device synced). The
            // reconcile should still be a clean no-write — no
            // upsert of a tombstoned row that just clutters the
            // cache.
            final now = DateTime.now().toUtc();
            final serverTombstone = GameCollection(
              id: 'server-tomb-id',
              userId: _kUserId,
              platformGameId: _kPlatformGameId,
              medium: _kMedium,
              quantity: 1,
              isDirty: false,
              isLocalOnly: false,
              deletedAt: now,
              createdAt: now,
              updatedAt: now,
            );

            await repo.reconcileFromServer(serverTombstone);

            expect(await db.select(db.gameCollectionsTable).get(), isEmpty);
          },
        );

        test('preserves a local-only resurrection when a stale tombstone '
            'confirmation arrives', () async {
          // The race the surgical-purge fix in 9ebd91dd defends
          // against:
          //
          // 1. User adds → server-confirmed (id=X, deletedAt=null,
          //    isLocalOnly=false).
          // 2. User removes → tombstone (id=X, deletedAt=t0,
          //    isLocalOnly=false). RemoveOp queued.
          // 3. RemoveOp completes → server has tombstoned id=X.
          // 4. User re-adds. addToCollection finds the local
          //    tombstone via _findCanonicalRow and resurrects:
          //    same id, deletedAt cleared, isLocalOnly flipped
          //    to true. Pending AddOp queued.
          // 5. The server's confirmation of step-2's removal —
          //    in flight the whole time — finally arrives at
          //    reconcileFromServer with serverEntry.id=X,
          //    deletedAt != null.
          //
          // Set up the post-removal, pre-resurrection state
          // directly: a server-confirmed tombstone exists locally
          // with id 'shared-id'.
          final t0 = DateTime.now().toUtc().subtract(
            const Duration(minutes: 5),
          );
          await db
              .into(db.gameCollectionsTable)
              .insert(
                GameCollectionsTableCompanion.insert(
                  id: 'shared-id',
                  userId: _kUserId,
                  platformGameId: _kPlatformGameId,
                  medium: 'Physical',
                  quantity: const Value(1),
                  deletedAt: Value(t0),
                  isLocalOnly: const Value(false),
                  createdAt: t0.subtract(const Duration(hours: 1)),
                  updatedAt: t0,
                ),
              );

          // Step 4: user re-adds. _findCanonicalRow picks up the
          // tombstone and addToCollection resurrects it with the
          // same id.
          final resurrected = await repo.addToCollection(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
            quantity: 1,
            rating: 9,
          );
          expect(resurrected.id, equals('shared-id'));
          expect(resurrected.deletedAt, isNull);
          expect(resurrected.isLocalOnly, isTrue);
          expect(resurrected.rating, equals(9));

          // Step 5: the stale tombstone confirmation arrives.
          // serverEntry carries the deletedAt the server has on
          // record for the row — from BEFORE the user re-added.
          final staleTombstone = GameCollection(
            id: 'shared-id',
            userId: _kUserId,
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
            quantity: 1,
            isDirty: false,
            isLocalOnly: false,
            deletedAt: t0,
            createdAt: t0.subtract(const Duration(hours: 1)),
            updatedAt: t0,
          );
          await repo.reconcileFromServer(
            staleTombstone,
            completedSyncQueueId: 'sq-stale-remove',
          );

          // The resurrection survives unchanged. The reconcile
          // didn't touch it.
          final live = await repo.getCollectionEntry(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
          );
          expect(live, isNotNull);
          expect(live!.id, equals('shared-id'));
          expect(live.deletedAt, isNull);
          expect(live.isLocalOnly, isTrue);
          expect(live.rating, equals(9));
          expect(live.quantity, equals(1));

          // The stale RemoveOp's sync-queue entry is still marked
          // completed — the reconcile-side queue closure fires
          // regardless of what the purge predicate matched. The
          // AddOp the resurrection enqueued stays untouched in
          // the queue (the mock tracks calls only; the AddOp
          // isn't a markCompleted target here).
          verify(() => mockSync.markCompleted('sq-stale-remove')).called(1);
        });
      });

      group('id reassignment + pending-op remap', () {
        test(
          'calls remapCollectionId(local.id, serverEntry.id) when ids differ',
          () async {
            // The integration shape: a local-only row exists with
            // its cuid2 id. The server reassigns to a different
            // canonical id. reconcileFromServer must rewrite any
            // pending Update/Remove ops that referenced the old
            // local id BEFORE dropping the row.
            final local = await repo.addToCollection(
              platformGameId: _kPlatformGameId,
              medium: _kMedium,
            );
            // Clear earlier mock interactions from the addToCollection
            // call so the verify below only inspects the reconcile path.
            clearInteractions(mockSync);
            _stubMockSyncDefaults(mockSync);

            final serverEntry = local.copyWith(
              id: 'server-canonical',
              isDirty: false,
              isLocalOnly: false,
            );
            await repo.reconcileFromServer(serverEntry);

            verify(
              () => mockSync.remapCollectionId(
                oldCollectionId: local.id,
                newCollectionId: 'server-canonical',
              ),
            ).called(1);
          },
        );

        test('does NOT call remapCollectionId when ids match', () async {
          // Optimistic case: the client-generated cuid2 round-tripped
          // through the server unchanged. No remap needed; the
          // method is skipped entirely (and importantly, no
          // self-targeting rewrite is performed against the queue).
          final local = await repo.addToCollection(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
          );
          clearInteractions(mockSync);
          _stubMockSyncDefaults(mockSync);

          final serverEntry = local.copyWith(
            isDirty: false,
            isLocalOnly: false,
          );
          await repo.reconcileFromServer(serverEntry);

          verifyNever(
            () => mockSync.remapCollectionId(
              oldCollectionId: any(named: 'oldCollectionId'),
              newCollectionId: any(named: 'newCollectionId'),
            ),
          );
        });

        test(
          'does NOT call remapCollectionId when no local row exists',
          () async {
            // Fresh server entry, never seen locally (e.g. another
            // device added it). No queued ops can possibly reference
            // this id, so the remap is a no-op skip.
            final now = DateTime.now().toUtc();
            final serverEntry = GameCollection(
              id: 'server-only-id',
              userId: _kUserId,
              platformGameId: _kPlatformGameId,
              medium: _kMedium,
              quantity: 1,
              isDirty: false,
              isLocalOnly: false,
              createdAt: now,
              updatedAt: now,
            );

            await repo.reconcileFromServer(serverEntry);

            verifyNever(
              () => mockSync.remapCollectionId(
                oldCollectionId: any(named: 'oldCollectionId'),
                newCollectionId: any(named: 'newCollectionId'),
              ),
            );
            // Row landed correctly.
            final live = await repo.getCollectionEntry(
              platformGameId: _kPlatformGameId,
              medium: _kMedium,
            );
            expect(live, isNotNull);
            expect(live!.id, equals('server-only-id'));
          },
        );

        test('calls remapCollectionId on a tombstone reconciliation when '
            'ids differ', () async {
          // Even on the tombstone branch, queued Update/Remove ops
          // still reference the old local id and must be rewritten
          // — the server may have ack'd the delete while the
          // earlier queued ops were still in flight under the
          // local-only id.
          final local = await repo.addToCollection(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
          );
          clearInteractions(mockSync);
          _stubMockSyncDefaults(mockSync);

          final now = DateTime.now().toUtc();
          final serverTombstone = local.copyWith(
            id: 'server-tomb-id',
            isDirty: false,
            isLocalOnly: false,
            deletedAt: now,
            updatedAt: now,
          );
          await repo.reconcileFromServer(serverTombstone);

          verify(
            () => mockSync.remapCollectionId(
              oldCollectionId: local.id,
              newCollectionId: 'server-tomb-id',
            ),
          ).called(1);
        });
      });
    });

    group('getCollection()', () {
      test('returns entries for current user only', () async {
        await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );

        await _seedPlatformGame(db, id: 'pg-other');
        final otherRepo = GameCollectionRepositoryImpl(
          db: db,
          syncQueue: mockSync,
          currentUserId: 'other-user',
        );
        await otherRepo.addToCollection(
          platformGameId: 'pg-other',
          medium: GameMedium.digital,
        );

        final myCollection = await repo.getCollection();
        expect(myCollection.every((e) => e.userId == _kUserId), isTrue);
        expect(myCollection, hasLength(1));
      });

      test('excludes tombstoned entries', () async {
        final entry = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );
        await repo.removeFromCollection(entry.id);

        expect(await repo.getCollection(), isEmpty);
      });
    });

    group('watchCollection()', () {
      test('emits current collection on subscribe', () async {
        await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );

        await expectLater(repo.watchCollection().take(1), emits(hasLength(1)));
      });

      test('excludes tombstoned entries', () async {
        final entry = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );
        await repo.removeFromCollection(entry.id);

        await expectLater(repo.watchCollection().take(1), emits(isEmpty));
      });
    });

    group('watchEntry()', () {
      test('emits null for an id belonging to a different user', () async {
        await _seedPlatformGame(db, id: 'pg-other');
        final now = DateTime.now().toUtc();
        await db
            .into(db.gameCollectionsTable)
            .insert(
              GameCollectionsTableCompanion.insert(
                id: 'other-entry',
                userId: 'other-user',
                platformGameId: 'pg-other',
                medium: 'Physical',
                createdAt: now,
                updatedAt: now,
              ),
            );

        await expectLater(
          repo.watchEntry('other-entry').take(1),
          emits(isNull),
        );
      });

      test('emits null after the entry is tombstoned', () async {
        final entry = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );

        final futureEmissions = repo.watchEntry(entry.id).take(2).toList();
        await pumpEventQueue();

        await repo.removeFromCollection(entry.id);

        final emissions = await futureEmissions.timeout(
          const Duration(seconds: 5),
        );
        expect(emissions, hasLength(2));
        expect(emissions[0]!.id, equals(entry.id));
        expect(emissions[0]!.deletedAt, isNull);
        expect(emissions[1], isNull);
      });
    });
  });
}
