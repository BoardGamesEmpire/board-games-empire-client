import 'package:di/di.dart' show LocalClockService;
import 'package:drift_storage/drift_storage.dart';
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:models/domain.dart';
import 'package:sync_queue/sync_queue.dart';

import 'fake_remotes.dart';

const kUserId = 'user-abc';

/// The platform game every collection fixture names. Seeded by [Harness.open],
/// because a collection row has an enforced foreign key onto it.
const kPlatformGameId = 'pg-1';

/// What a server answers for a household create.
Household serverHousehold({
  String id = 'hh-server',
  String name = 'HQ',
  DateTime? deletedAt,
}) => Household(
  id: id,
  name: name,
  deletedAt: deletedAt,
  createdAt: DateTime.utc(2026, 10),
  updatedAt: DateTime.utc(2026, 10),
);

/// What a server answers for a collection write on the fixture platform game.
GameCollection serverEntry({
  String id = 'gc-server',
  int quantity = 1,
  DateTime? deletedAt,
  DateTime? updatedAt,
}) => GameCollection(
  id: id,
  userId: kUserId,
  platformGameId: kPlatformGameId,
  medium: GameMedium.physical,
  quantity: quantity,
  deletedAt: deletedAt,
  createdAt: DateTime.utc(2026, 10),
  updatedAt: updatedAt ?? DateTime.utc(2026, 10, 2),
);

/// The real repositories over one in-memory database, fake remotes, and a
/// sender over all of them: what a user session holds, without a network.
///
/// [deviceNow] is the device clock the queue stamps claims and failures
/// with, and the drain measures cooldowns on. Tests move it with [advance]
/// rather than wait.
class Harness {
  Harness._(this.db, this._clock);

  final ServerDatabase db;
  final _DeviceClock _clock;

  /// Moves the device clock forward by [by].
  void advance(Duration by) => _clock.now = _clock.now.add(by);

  DateTime deviceNow() => _clock.now;

  late SyncQueueRepositoryImpl queue = _openQueue();
  late HouseholdRepositoryImpl households = _openHouseholds();
  late GameCollectionRepositoryImpl collection = _openCollection();

  SyncQueueRepositoryImpl _openQueue() => SyncQueueRepositoryImpl(
    db,
    const LocalClockService(),
    userId: kUserId,
    localNowUtc: deviceNow,
  );

  HouseholdRepositoryImpl _openHouseholds() => HouseholdRepositoryImpl(
    db: db,
    currentUserId: () => kUserId,
    syncQueue: queue,
    clock: const LocalClockService(),
  );

  GameCollectionRepositoryImpl _openCollection() =>
      GameCollectionRepositoryImpl(
        db: db,
        syncQueue: queue,
        currentUserId: kUserId,
        clock: const LocalClockService(),
      );

  /// Ends this session's repositories, as a scope pop does, and opens a new
  /// session's over the same database: a sign-out and back in, or a switch
  /// away and back. The sender is rebuilt over the new ones.
  Future<void> newSession() async {
    await collection.onDispose();
    await households.onDispose();
    await queue.onDispose();
    queue = _openQueue();
    households = _openHouseholds();
    collection = _openCollection();
    sender = _openSender();
  }

  final FakeHouseholdRemote householdRemote = FakeHouseholdRemote(
    (_) => serverHousehold(),
  );
  final FakeCollectionRemote collectionRemote = FakeCollectionRemote(
    (_) => serverEntry(),
  );

  late SyncOperationSenderImpl sender = _openSender();

  SyncOperationSenderImpl _openSender() => SyncOperationSenderImpl(
    queue: queue,
    households: households,
    householdRemote: householdRemote,
    collection: collection,
    collectionRemote: collectionRemote,
  );

  static Future<Harness> open() async {
    final db = inMemoryServerDatabase();
    final harness = Harness._(db, _DeviceClock(DateTime.utc(2026, 10, 12, 9)));
    await GameRepositoryImpl(db).cachePlatformGameSummaries(const [
      PlatformGameSummary(
        id: kPlatformGameId,
        platformId: 'plat-1',
        platformName: 'Tabletop',
        game: GameSummary(id: 'g-1', title: 'Brass'),
      ),
    ]);
    return harness;
  }

  Future<void> close() => db.close();

  /// The queue entry [id], whatever its status.
  Future<SyncQueueEntry> entry(String id) async =>
      (await queue.getAllEntries()).singleWhere((e) => e.id == id);

  /// Creates a household offline: the optimistic row and its queued create.
  Future<({Household household, CreateHouseholdOperation op, String id})>
  queuedCreate({String name = 'HQ'}) async {
    final draft = await households.create(name: name);
    final entry = await this.entry(draft.syncQueueId);
    return (
      household: draft.household,
      op: entry.operation as CreateHouseholdOperation,
      id: entry.id,
    );
  }

  /// Adds the fixture game offline: the local-only row and its queued add.
  Future<({GameCollection local, AddToCollectionOperation op, String id})>
  queuedAdd({int quantity = 1}) async {
    final local = await collection.addToCollection(
      platformGameId: kPlatformGameId,
      medium: GameMedium.physical,
      quantity: quantity,
    );
    final entry = (await queue.getAllEntries()).last;
    return (
      local: local,
      op: entry.operation as AddToCollectionOperation,
      id: entry.id,
    );
  }

  /// A server-confirmed entry for the fixture game: added, then acknowledged
  /// under [serverId].
  Future<void> confirmedEntry({String serverId = 'gc-server'}) async {
    final add = await queuedAdd();
    await collection.reconcileFromServer(
      serverEntry(id: serverId),
      completedSyncQueueId: add.id,
    );
  }

  /// The one live entry the collection holds.
  Future<GameCollection> onlyEntry() async =>
      (await collection.getCollection()).single;

  /// Whether a hydrate starting now can write the fixture game: a newer
  /// server copy merges in only when no dirty or local-only row, tombstone
  /// included, sits on its triplet. That is how a purge shows through the
  /// public API, since reads hide a tombstone either way. Writes the copy if
  /// it can.
  Future<bool> hydrateCanWriteFixtureGame() async {
    final mark = await collection.removalMark();
    await collection.mergeFromServer([
      serverEntry(id: 'gc-hydrated', quantity: 9, updatedAt: DateTime(2027)),
    ], removalsSince: mark);
    final live = await collection.getCollection();
    return live.length == 1 && live.single.quantity == 9;
  }
}

class _DeviceClock {
  _DeviceClock(this.now);

  DateTime now;
}
