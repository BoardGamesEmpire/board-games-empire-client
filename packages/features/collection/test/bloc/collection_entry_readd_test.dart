import 'package:di/di.dart' show LocalClockService;
import 'package:drift_storage/drift_storage.dart';
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

class _MockSyncOperationSender extends Mock implements SyncOperationSender {}

const _userId = 'user-abc';

/// Midday, so the date is the same in any test time zone.
final _lastPlayed = DateTime.utc(2026, 3, 14, 12);

/// Remove then re-add keeps play history (#46's re-scope), through the
/// detail's bloc over the real repository: plays reach the cache only from
/// server data (#258), and a re-add revives the removed row rather than
/// starting a new one (`addToCollection`'s resurrection rules).
void main() {
  late ServerDatabase db;
  late GameCollectionRepositoryImpl collection;
  late _MockSyncOperationSender sender;

  setUpAll(() {
    registerFallbackValue(
      const RemoveFromCollectionOperation(collectionId: 'fallback'),
    );
  });

  setUp(() async {
    db = inMemoryServerDatabase();
    collection = GameCollectionRepositoryImpl(
      db: db,
      syncQueue: SyncQueueRepositoryImpl(
        db,
        const LocalClockService(),
        userId: _userId,
      ),
      currentUserId: _userId,
      clock: const LocalClockService(),
    );
    sender = _MockSyncOperationSender();
    // The server can't be reached: each op stays queued, as offline.
    when(() => sender.deliver(any(), any()))
        .thenAnswer((_) async => const SyncNotClaimed());

    // As a hydrate brings it: the summary the entry's row joins, then the
    // entry with its play history.
    await GameRepositoryImpl(db, userId: _userId).cachePlatformGameSummaries(
      const [
        PlatformGameSummary(
          id: 'pg-1',
          platformId: 'plat-1',
          platformName: 'Board game',
          game: GameSummary(id: 'g-1', title: 'Wingspan'),
        ),
      ],
    );
    await collection.mergeFromServer([
      GameCollection(
        id: 'gc-1',
        userId: _userId,
        platformGameId: 'pg-1',
        medium: GameMedium.physical,
        quantity: 2,
        playCount: 12,
        lastPlayed: _lastPlayed,
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
      ),
    ], removalsSince: await collection.removalMark());
  });

  tearDown(() async => db.close());

  CollectionEntryBloc open() => CollectionEntryBloc(
    repository: collection,
    sender: sender,
    entryId: 'gc-1',
  );

  Future<CollectionEntryState> ready(CollectionEntryBloc bloc) =>
      bloc.state.view == CollectionEntryView.ready
      ? Future.value(bloc.state)
      : bloc.stream.firstWhere(
          (state) => state.view == CollectionEntryView.ready,
        );

  test('remove then re-add keeps the play count and last played', () async {
    final detail = open();
    final before = (await ready(detail)).item!.entry;
    expect(before.playCount, 12);

    detail.add(const CollectionEntryRemoveConfirmed());
    final removed = await detail.stream.firstWhere(
      (state) => state.action != CollectionEntryAction.removing,
    );
    expect(removed.action, CollectionEntryAction.removed);
    await detail.close();
    expect(await collection.watchCollectionListItem('gc-1').first, isNull);

    final readded = await collection.addToCollection(
      platformGameId: 'pg-1',
      medium: GameMedium.physical,
    );
    // The removed row came back, under its id.
    expect(readded.entry.id, 'gc-1');

    final reopened = open();
    addTearDown(reopened.close);
    final entry = (await ready(reopened)).item!.entry;

    expect(entry.playCount, 12);
    expect(entry.lastPlayed, isNotNull);
    expect(entry.lastPlayed!.isAtSameMomentAs(_lastPlayed), isTrue);
    // A re-add is a fresh ownership: its quantity, not the old one.
    expect(entry.quantity, 1);
  });
}
