import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:drift_storage/src/databases/server_database.dart';
import 'package:drift_storage/src/repositories/household_repository_impl.dart';
import 'package:drift_storage/src/repositories/sync_queue_repository_impl.dart';

import '../support/fixed_clock.dart';

// The hydrate's authority over the cache (#268): the roster write that
// replaces a household's members with the server's, and the purge that
// removes households a snapshot no longer contains.

const _kUserId = 'user-abc';
const _kOtherUserId = 'user-other';
final _t = DateTime.utc(2024, 1, 15, 10, 30);

Household _household(String id, {String? name}) => Household(
  id: id,
  name: name ?? 'Household $id',
  createdAt: _t,
  updatedAt: _t,
);

HouseholdMember _member(String householdId, String userId, {String? id}) =>
    HouseholdMember(
      id: id ?? 'm-$householdId-$userId',
      userId: userId,
      householdId: householdId,
      role: HouseholdRole.householdMember,
      createdAt: _t,
      updatedAt: _t,
    );

void main() {
  late ServerDatabase db;
  late HouseholdRepositoryImpl repo;

  setUp(() {
    db = inMemoryServerDatabase();
    final clock = FixedClockService(_t);
    repo = HouseholdRepositoryImpl(
      db: db,
      currentUserId: () => _kUserId,
      syncQueue: SyncQueueRepositoryImpl(db, clock, userId: _kUserId),
      clock: clock,
    );
  });

  tearDown(() async => db.close());

  group('cacheHouseholdWithRoster', () {
    test('drops a member the server roster no longer lists', () async {
      await repo.cacheHouseholdWithRoster(_household('h-1'), [
        _member('h-1', _kUserId),
        _member('h-1', _kOtherUserId),
      ]);

      final write = await repo.cacheHouseholdWithRoster(_household('h-1'), [
        _member('h-1', _kUserId),
      ]);

      expect(write, equals(HouseholdRosterWrite.replaced));
      final members = await repo.getMembers('h-1');
      expect(members.map((m) => m.userId), equals([_kUserId]));
    });

    test('leaves a dirty household and its roster alone', () async {
      // The queue owns a dirty row until the server acknowledges it (#298),
      // and #122's membership ops will lean on that to hold a local leave
      // or kick against the next hydrate.
      await _seedHousehold(db, id: 'h-1', name: 'Local edit', isDirty: true);
      await _seedMember(db, householdId: 'h-1', userId: _kUserId);
      await _seedMember(db, householdId: 'h-1', userId: _kOtherUserId);

      final write = await repo.cacheHouseholdWithRoster(
        _household('h-1', name: 'Server'),
        [_member('h-1', _kUserId)],
      );

      expect(write, equals(HouseholdRosterWrite.held));
      expect((await repo.getHousehold('h-1'))!.name, equals('Local edit'));
      final members = await repo.getMembers('h-1');
      expect(
        members.map((m) => m.userId),
        unorderedEquals([_kUserId, _kOtherUserId]),
      );
    });

    test('leaves a local-only household and its roster alone', () async {
      // A create the server has not confirmed. Its synthesized owner row is
      // the only thing surfacing it in the list.
      final created = await repo.create(name: 'Not synced yet');
      final id = created.household.id;

      final write = await repo.cacheHouseholdWithRoster(
        _household(id, name: 'Server'),
        [_member(id, _kUserId), _member(id, _kOtherUserId)],
      );

      expect(write, equals(HouseholdRosterWrite.held));
      expect((await repo.getHousehold(id))!.name, equals('Not synced yet'));
      final members = await repo.getMembers(id);
      expect(members.map((m) => m.userId), equals([_kUserId]));
    });

    test('an empty roster refreshes the household but removes no one, and '
        'reports it', () async {
      // The adapter reads an absent `members` key as an empty roster. Taken
      // at its word it would delete the current user's own row, and the
      // household would vanish from their list.
      await repo.cacheHouseholdWithRoster(_household('h-1'), [
        _member('h-1', _kUserId),
        _member('h-1', _kOtherUserId),
      ]);

      final write = await repo.cacheHouseholdWithRoster(
        _household('h-1', name: 'Renamed'),
        const [],
      );

      expect(write, equals(HouseholdRosterWrite.merged));
      expect((await repo.getHousehold('h-1'))!.name, equals('Renamed'));
      final members = await repo.getMembers('h-1');
      expect(
        members.map((m) => m.userId),
        unorderedEquals([_kUserId, _kOtherUserId]),
      );
    });

    test('a roster without the current user removes no one, and reports '
        'it', () async {
      // The list is membership-scoped, so every household in it has the
      // caller on its roster. One that does not is a roster the read did
      // not carry in full.
      await repo.cacheHouseholdWithRoster(_household('h-1'), [
        _member('h-1', _kUserId),
        _member('h-1', _kOtherUserId),
        _member('h-1', 'user-third'),
      ]);

      final write = await repo.cacheHouseholdWithRoster(_household('h-1'), [
        _member('h-1', _kOtherUserId),
      ]);

      expect(write, equals(HouseholdRosterWrite.merged));
      final members = await repo.getMembers('h-1');
      expect(
        members.map((m) => m.userId),
        unorderedEquals([_kUserId, _kOtherUserId, 'user-third']),
      );
    });
  });

  group('purgeHouseholdsAbsentFrom', () {
    Future<HouseholdsTableData?> rawHousehold(String id) => (db.select(
      db.householdsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();

    Future<List<HouseholdMembersTableData>> rawMembers(String householdId) =>
        (db.select(
          db.householdMembersTable,
        )..where((t) => t.householdId.equals(householdId))).get();

    test(
      'removes a household of mine the snapshot no longer contains',
      () async {
        // Removed from it or deleted outright: the list cannot tell the two
        // apart, and nothing here needs to.
        await repo.cacheHouseholdWithRoster(_household('h-kept'), [
          _member('h-kept', _kUserId),
        ]);
        await repo.cacheHouseholdWithRoster(_household('h-gone'), [
          _member('h-gone', _kUserId),
        ]);
        final purgeable = await repo.purgeableHouseholdIds();

        final purged = await repo.purgeHouseholdsAbsentFrom({
          'h-kept',
        }, purgeable: purgeable);

        expect(purged, equals({'h-gone'}));
        final listed = await repo.getHouseholds();
        expect(listed.map((h) => h.id), equals(['h-kept']));
        expect(await rawHousehold('h-gone'), isNull);
        expect(await rawMembers('h-gone'), isEmpty);
      },
    );

    test('removes only my membership, keeping everyone else in the '
        'household', () async {
      // Everyone who signs in to this server on this device shares the
      // cache. The snapshot says the current user is out; it says nothing
      // about whether the next person to sign in here still belongs.
      await repo.cacheHouseholdWithRoster(_household('h-shared'), [
        _member('h-shared', _kUserId),
        _member('h-shared', _kOtherUserId),
      ]);
      final purgeable = await repo.purgeableHouseholdIds();

      final purged = await repo.purgeHouseholdsAbsentFrom(
        const {},
        purgeable: purgeable,
      );

      expect(purged, equals({'h-shared'}));
      expect(await repo.getHouseholds(), isEmpty);
      expect(await rawHousehold('h-shared'), isNotNull);
      final left = await rawMembers('h-shared');
      expect(left.map((m) => m.userId), equals([_kOtherUserId]));
    });

    test('keeps a household the server has not seen yet', () async {
      // Local-only, so never purgeable: the queue owns it.
      final created = await repo.create(name: 'Not synced yet');

      final purged = await repo.purgeHouseholdsAbsentFrom(
        const {},
        purgeable: await repo.purgeableHouseholdIds(),
      );

      expect(purged, isEmpty);
      final listed = await repo.getHouseholds();
      expect(listed.map((h) => h.id), equals([created.household.id]));
    });

    test('keeps a dirty household', () async {
      await _seedHousehold(db, id: 'h-1', isDirty: true);
      await _seedMember(db, householdId: 'h-1', userId: _kUserId);

      final purged = await repo.purgeHouseholdsAbsentFrom(
        const {},
        purgeable: await repo.purgeableHouseholdIds(),
      );

      expect(purged, isEmpty);
      expect(await repo.getHousehold('h-1'), isNotNull);
    });

    test('keeps a household edited after the purgeable read', () async {
      // The edit hands it to the queue while the snapshot is in flight.
      await repo.cacheHouseholdWithRoster(_household('h-1'), [
        _member('h-1', _kUserId),
      ]);
      final purgeable = await repo.purgeableHouseholdIds();
      await (db.update(db.householdsTable)..where((t) => t.id.equals('h-1')))
          .write(const HouseholdsTableCompanion(isDirty: Value(true)));

      final purged = await repo.purgeHouseholdsAbsentFrom(
        const {},
        purgeable: purgeable,
      );

      expect(purged, isEmpty);
      expect(await repo.getHousehold('h-1'), isNotNull);
    });

    test('leaves a household I have no member row in untouched', () async {
      // The list speaks for the caller's own memberships and nothing else,
      // so its silence about any other household proves nothing.
      await repo.cacheHouseholdWithRoster(_household('h-theirs'), [
        _member('h-theirs', _kOtherUserId),
      ]);

      final purged = await repo.purgeHouseholdsAbsentFrom(
        const {},
        purgeable: {'h-theirs'},
      );

      expect(purged, isEmpty);
      expect(await rawHousehold('h-theirs'), isNotNull);
      expect(await rawMembers('h-theirs'), hasLength(1));
    });

    Future<void> reconcile(
      HouseholdRepositoryImpl on,
      ({Household household, String syncQueueId}) created, {
      required String serverId,
    }) => on.reconcileCreatedHousehold(
      created.household.copyWith(
        id: serverId,
        isDirty: false,
        isLocalOnly: false,
      ),
      localId: created.household.id,
      completedSyncQueueId: created.syncQueueId,
    );

    test(
      'keeps a create reconciled after the snapshot was requested',
      () async {
        // The inline create races a hydrate in flight: the snapshot can miss
        // the household, and by the time the purge runs its flags are
        // cleared and the owner's member row is in place.
        final created = await repo.create(name: 'Just made');
        final purgeable = await repo.purgeableHouseholdIds();
        await reconcile(repo, created, serverId: 'h-server');

        final purged = await repo.purgeHouseholdsAbsentFrom(
          const {},
          purgeable: purgeable,
        );

        expect(purged, isEmpty);
        final listed = await repo.getHouseholds();
        expect(listed.map((h) => h.id), equals(['h-server']));
      },
    );

    test('keeps a household another tab created during the pass', () async {
      // Two repositories over one database: what the web gives two tabs
      // that share storage. Nothing this repository holds in memory could
      // see the other tab's write; the database can.
      final clock = FixedClockService(_t);
      final otherTab = HouseholdRepositoryImpl(
        db: db,
        currentUserId: () => _kUserId,
        syncQueue: SyncQueueRepositoryImpl(db, clock, userId: _kUserId),
        clock: clock,
      );
      final purgeable = await repo.purgeableHouseholdIds();
      final created = await otherTab.create(name: 'Made in the other tab');
      await reconcile(otherTab, created, serverId: 'h-server');

      final purged = await repo.purgeHouseholdsAbsentFrom(
        const {},
        purgeable: purgeable,
      );

      expect(purged, isEmpty);
      final listed = await repo.getHouseholds();
      expect(listed.map((h) => h.id), equals(['h-server']));
    });

    test('keeps a household that became mine after the purgeable read, '
        'whichever writer landed it', () async {
      // Joining through an invite, say: nothing about the writer has to
      // know the purge exists.
      final purgeable = await repo.purgeableHouseholdIds();
      await repo.cacheHouseholdWithRoster(_household('h-joined'), [
        _member('h-joined', _kUserId),
      ]);

      final purged = await repo.purgeHouseholdsAbsentFrom(
        const {},
        purgeable: purgeable,
      );

      expect(purged, isEmpty);
      expect(await repo.getHousehold('h-joined'), isNotNull);
    });

    test('removes a create reconciled before the snapshot was requested, '
        'once the snapshot lacks it', () async {
      // The read spares only what the snapshot could not have seen. A
      // household the server confirmed before the request is one the
      // snapshot speaks for.
      final created = await repo.create(name: 'Made earlier');
      await reconcile(repo, created, serverId: 'h-server');

      final purged = await repo.purgeHouseholdsAbsentFrom(
        const {},
        purgeable: await repo.purgeableHouseholdIds(),
      );

      expect(purged, equals({'h-server'}));
      expect(await repo.getHouseholds(), isEmpty);
    });
  });
}

Future<void> _seedHousehold(
  ServerDatabase db, {
  required String id,
  String name = 'Test Household',
  bool isDirty = false,
  bool isLocalOnly = false,
}) => db
    .into(db.householdsTable)
    .insert(
      HouseholdsTableCompanion.insert(
        id: id,
        name: name,
        isDirty: Value(isDirty),
        isLocalOnly: Value(isLocalOnly),
        createdAt: _t,
        updatedAt: _t,
      ),
    );

Future<void> _seedMember(
  ServerDatabase db, {
  required String householdId,
  required String userId,
}) => db
    .into(db.householdMembersTable)
    .insert(
      HouseholdMembersTableCompanion.insert(
        id: 'seed-$householdId-$userId',
        userId: userId,
        householdId: householdId,
        createdAt: _t,
        updatedAt: _t,
      ),
    );
