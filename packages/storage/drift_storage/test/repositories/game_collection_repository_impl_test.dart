import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_collection_repository_impl.dart';

class MockSyncQueue extends Mock implements SyncQueueRepository {}

// ── Fixtures ────────────────────────────────────────────────────────────────────

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

// ── Tests ────────────────────────────────────────────────────────────────────

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

    when(() => mockSync.enqueue(any())).thenAnswer(
      (_) async => SyncQueueEntry(
        id: 'sq-1',
        payload: '{}',
        createdAt: DateTime.now().toUtc(),
      ),
    );

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

      test('enqueues UpdateCollectionOperation', () async {
        final entry = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );

        await repo.updateCollectionEntry(id: entry.id, playCount: 3);

        verify(
          () => mockSync.enqueue(any(that: isA<UpdateCollectionOperation>())),
        ).called(greaterThan(0));
      });

      test('throws StateError when entry belongs to a different user', () async {
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

        // Untouched.
        final row = await (db.select(db.gameCollectionsTable)
              ..where((t) => t.id.equals('other-entry')))
            .getSingle();
        expect(row.rating, equals(7));
        expect(row.userId, equals('other-user'));
      });

      test(
        'does NOT enqueue a sync op when the entry is not found (transaction rolled back)',
        () async {
          await expectLater(
            () => repo.updateCollectionEntry(
              id: 'nonexistent',
              rating: 1,
            ),
            throwsStateError,
          );
          verifyNever(() => mockSync.enqueue(any()));
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

        // The repo's user-facing reads hide tombstones now.
        expect(
          await repo.getCollectionEntry(
            platformGameId: _kPlatformGameId,
            medium: _kMedium,
          ),
          isNull,
        );

        // Underlying row still exists with deletedAt set.
        final row = await (db.select(db.gameCollectionsTable)
              ..where((t) => t.id.equals(entry.id)))
            .getSingleOrNull();
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

      test('throws StateError when entry belongs to a different user', () async {
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

        final row = await (db.select(db.gameCollectionsTable)
              ..where((t) => t.id.equals('other-entry')))
            .getSingle();
        expect(row.deletedAt, isNull);
      });
    });

    group('transaction atomicity', () {
      test(
        'addToCollection rolls back the local insert when enqueue throws',
        () async {
          when(() => mockSync.enqueue(any()))
              .thenThrow(Exception('queue offline'));

          await expectLater(
            () => repo.addToCollection(
              platformGameId: _kPlatformGameId,
              medium: _kMedium,
            ),
            throwsException,
          );

          // No row should have been persisted.
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

          when(() => mockSync.enqueue(any()))
              .thenThrow(Exception('queue offline'));

          await expectLater(
            () => repo.removeFromCollection(entry.id),
            throwsException,
          );

          // Tombstone must not have been written.
          final row = await (db.select(db.gameCollectionsTable)
                ..where((t) => t.id.equals(entry.id)))
              .getSingle();
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

        // Old local row should be gone.
        expect(
          await (db.select(db.gameCollectionsTable)
                ..where((t) => t.id.equals(local.id)))
              .getSingleOrNull(),
          isNull,
        );
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

        await expectLater(
          repo.watchCollection().take(1),
          emits(hasLength(1)),
        );
      });

      test('excludes tombstoned entries', () async {
        final entry = await repo.addToCollection(
          platformGameId: _kPlatformGameId,
          medium: _kMedium,
        );
        await repo.removeFromCollection(entry.id);

        await expectLater(
          repo.watchCollection().take(1),
          emits(isEmpty),
        );
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

        await expectLater(repo.watchEntry('other-entry').take(1), emits(isNull));
      });
    });
  });
}
