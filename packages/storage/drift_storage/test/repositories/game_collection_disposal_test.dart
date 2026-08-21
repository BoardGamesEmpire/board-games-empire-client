import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/game_collection_repository_impl.dart';

import '../support/platform_game_fixture.dart';
import '../support/system_clock.dart';

class MockSyncQueue extends Mock implements SyncQueueRepository {}

const _kUserA = 'user-a';
const _kUserB = 'user-b';
const _kMedium = GameMedium.physical;

/// Disposal contract for [GameCollectionRepositoryImpl] (#150), mirroring
/// the group `sync_queue_user_scoping_test.dart` holds for the queue.
///
/// The repository is registered in the **user-session scope** (#135), which
/// pops on every authentication transition, while its Drift streams are
/// tied to the per-server database that outlives that scope. Without the
/// shared [WatchDisposal] contract a subscription taken under user A keeps
/// emitting A's frozen rows after B signs in — the #138 leak.
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
  });

  late ServerDatabase db;
  late MockSyncQueue mockSync;
  late GameCollectionRepositoryImpl repoA;

  GameCollectionRepositoryImpl repositoryFor(String userId) =>
      GameCollectionRepositoryImpl(
        db: db,
        syncQueue: mockSync,
        currentUserId: userId,
        clock: const SystemClockService(),
      );

  setUp(() async {
    db = ServerDatabase.memory();
    mockSync = MockSyncQueue();
    when(() => mockSync.enqueue(any())).thenAnswer(
      (_) async => SyncQueueEntry(
        id: 'sq-stub',
        payload: '{}',
        createdAt: DateTime.now().toUtc(),
      ),
    );

    repoA = repositoryFor(_kUserA);

    await seedPlatformGame(db);
  });

  tearDown(() async => db.close());

  group('GameCollectionRepositoryImpl disposal (#135 / #138 / #150)', () {
    test(
      'onDispose closes a live watchCollection stream without an error',
      () async {
        var done = false;
        Object? streamError;
        final sub = repoA.watchCollection().listen(
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
      },
    );

    test(
      'onDispose closes a live watchEntry stream without an error',
      () async {
        final entry = await repoA.addToCollection(
          platformGameId: kFixturePlatformGameId,
          medium: _kMedium,
        );

        var done = false;
        Object? streamError;
        final sub = repoA
            .watchEntry(entry.id)
            .listen(
              (_) {},
              onError: (Object e) => streamError = e,
              onDone: () => done = true,
            );
        addTearDown(sub.cancel);
        await pumpEventQueue();
        expect(done, isFalse);

        await repoA.onDispose();
        await pumpEventQueue();

        expect(done, isTrue);
        expect(streamError, isNull);
      },
    );

    test(
      'watchCollection after disposal returns an already-closed stream',
      () async {
        await repoA.onDispose();

        await expectLater(repoA.watchCollection(), emitsDone);
      },
    );

    test(
      'watchEntry after disposal returns an already-closed stream',
      () async {
        await repoA.onDispose();

        await expectLater(repoA.watchEntry('any-id'), emitsDone);
      },
    );

    test('watch* never throw synchronously after disposal — subscribers can '
        'only observe what arrives on the stream', () async {
      await repoA.onDispose();

      expect(repoA.watchCollection, returnsNormally);
      expect(() => repoA.watchEntry('any-id'), returnsNormally);
    });

    test('read methods after disposal throw StateError', () async {
      await repoA.onDispose();

      await expectLater(repoA.getCollection(), throwsStateError);
      await expectLater(
        repoA.getCollectionEntry(
          platformGameId: kFixturePlatformGameId,
          medium: _kMedium,
        ),
        throwsStateError,
      );
    });

    test('mutation methods after disposal throw StateError', () async {
      final entry = await repoA.addToCollection(
        platformGameId: kFixturePlatformGameId,
        medium: _kMedium,
      );
      await repoA.onDispose();

      await expectLater(
        repoA.addToCollection(
          platformGameId: kFixturePlatformGameId,
          medium: GameMedium.digital,
        ),
        throwsStateError,
      );
      await expectLater(
        repoA.updateCollectionEntry(id: entry.id, quantity: 2),
        throwsStateError,
      );
      await expectLater(repoA.removeFromCollection(entry.id), throwsStateError);
    });

    test('reconcileFromServer after disposal throws StateError', () async {
      final entry = await repoA.addToCollection(
        platformGameId: kFixturePlatformGameId,
        medium: _kMedium,
      );
      await repoA.onDispose();

      await expectLater(
        repoA.reconcileFromServer(entry.copyWith(isDirty: false)),
        throwsStateError,
      );
    });

    test('a disposed repository rejects a write before it reaches the '
        'database or the sync queue', () async {
      await repoA.onDispose();

      await expectLater(
        repoA.addToCollection(
          platformGameId: kFixturePlatformGameId,
          medium: _kMedium,
        ),
        throwsStateError,
      );

      verifyNever(() => mockSync.enqueue(any()));
      expect(await db.select(db.gameCollectionsTable).get(), isEmpty);
    });

    test('the post-disposal error names the repository so a wiring bug is '
        'identifiable from the message alone', () async {
      await repoA.onDispose();

      await expectLater(
        repoA.getCollection(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('GameCollectionRepository'),
          ),
        ),
      );
    });

    test('onDispose is idempotent', () async {
      await repoA.onDispose();

      await expectLater(repoA.onDispose(), completes);
    });

    test('disposing one user\'s repository does not disturb another\'s live '
        'stream over the same table', () async {
      // The only case that needs a second live repository over the same
      // database — the shared-device shape.
      final repoB = repositoryFor(_kUserB);
      final events = <List<GameCollection>>[];
      final sub = repoB.watchCollection().listen(events.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      await repoA.onDispose();
      await repoB.addToCollection(
        platformGameId: kFixturePlatformGameId,
        medium: _kMedium,
      );
      await pumpEventQueue();

      expect(
        events.last.single.userId,
        _kUserB,
        reason: "user B's stream stays live after user A's scope pops",
      );
    });
  });
}
