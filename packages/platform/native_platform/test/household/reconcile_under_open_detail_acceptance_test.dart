import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:models/domain.dart';

/// #306's acceptance, over the real repository and database: a created
/// household reconciled onto the server's id while its detail screen is
/// open stays rendered, and a screen built on the local id afterwards
/// renders it too. #442's: the same holds for a screen in another tab,
/// whose repository is a second one over the same database.
///
/// The bloc suite covers the same behaviour against a mocked repository.
/// This exists for what a mock cannot reproduce: when drift delivers the
/// reconcile's stream updates relative to the repository recording where
/// the household went. If the screen hears the local row vanish before
/// that record exists, it reports the household as not found.
const _kUserId = 'user-abc';
const _kServerId = 'hh_server';

void main() {
  late ServerDatabase db;
  late SyncQueueRepositoryImpl syncQueue;
  late HouseholdRepositoryImpl repo;

  setUp(() {
    db = inMemoryServerDatabase();
    const clock = LocalClockService();
    syncQueue = SyncQueueRepositoryImpl(db, clock, userId: _kUserId);
    repo = HouseholdRepositoryImpl(
      db: db,
      currentUserId: () => _kUserId,
      syncQueue: syncQueue,
      clock: clock,
    );
  });

  tearDown(() async {
    await repo.onDispose();
    await syncQueue.onDispose();
    await db.close();
  });

  // What another web tab holds: its own repository over the same database,
  // which did not run the reconcile.
  HouseholdRepositoryImpl otherTab() {
    final other = HouseholdRepositoryImpl(
      db: db,
      currentUserId: () => _kUserId,
      syncQueue: syncQueue,
      clock: const LocalClockService(),
    );
    addTearDown(other.onDispose);
    return other;
  }

  Future<void> reconcile(({Household household, String syncQueueId}) created) =>
      repo.reconcileCreatedHousehold(
        created.household.copyWith(
          id: _kServerId,
          isDirty: false,
          isLocalOnly: false,
        ),
        localId: created.household.id,
        completedSyncQueueId: created.syncQueueId,
      );

  test('an open detail screen keeps the household rendered through the '
      'reconcile, and ends on the server id', () async {
    final created = await repo.create(name: 'Game Night HQ');
    final bloc = HouseholdDetailBloc(
      householdId: created.household.id,
      repository: repo,
    );
    final states = <HouseholdDetailState>[];
    final sub = bloc.stream.listen(states.add);
    await _until(bloc, (s) => s is HouseholdDetailReady);
    states.clear();

    await reconcile(created);
    await _until(
      bloc,
      (s) => s is HouseholdDetailReady && s.household.id == _kServerId,
    );

    expect(states, everyElement(isA<HouseholdDetailReady>()));
    expect(
      bloc.state,
      isA<HouseholdDetailReady>()
          .having((s) => s.memberCount, 'memberCount', 1)
          .having((s) => s.role, 'role', HouseholdRole.householdOwner),
    );

    await sub.cancel();
    await bloc.close();
  });

  test(
    'a detail screen built on the local id after the reconcile renders it',
    () async {
      final created = await repo.create(name: 'Game Night HQ');
      await reconcile(created);

      final bloc = HouseholdDetailBloc(
        householdId: created.household.id,
        repository: repo,
      );
      await _until(bloc, (s) => s is! HouseholdDetailLoading);

      expect(
        bloc.state,
        isA<HouseholdDetailReady>()
            .having((s) => s.household.id, 'household.id', _kServerId)
            .having((s) => s.role, 'role', HouseholdRole.householdOwner),
      );

      await bloc.close();
    },
  );

  test('an open detail screen in another tab keeps the household rendered '
      'through the reconcile, and ends on the server id (#442)', () async {
    final created = await repo.create(name: 'Game Night HQ');
    final bloc = HouseholdDetailBloc(
      householdId: created.household.id,
      repository: otherTab(),
    );
    final states = <HouseholdDetailState>[];
    final sub = bloc.stream.listen(states.add);
    await _until(bloc, (s) => s is HouseholdDetailReady);
    states.clear();

    await reconcile(created);
    await _until(
      bloc,
      (s) => s is HouseholdDetailReady && s.household.id == _kServerId,
    );

    // Never a moment of "no members" or no role: the old roster emptying
    // can reach this tab before the household list does.
    expect(
      states,
      everyElement(
        isA<HouseholdDetailReady>()
            .having((s) => s.memberCount, 'memberCount', 1)
            .having((s) => s.role, 'role', HouseholdRole.householdOwner),
      ),
    );

    await sub.cancel();
    await bloc.close();
  });

  test('a detail screen in another tab, built on the local id after the '
      'reconcile, renders it (#442)', () async {
    // The other tab's repository has read nothing yet, so it cannot name
    // the move when the screen is built; its first household emission can.
    final created = await repo.create(name: 'Game Night HQ');
    await reconcile(created);

    final bloc = HouseholdDetailBloc(
      householdId: created.household.id,
      repository: otherTab(),
    );
    await _until(bloc, (s) => s is! HouseholdDetailLoading);

    // The first paint, role included.
    expect(
      bloc.state,
      isA<HouseholdDetailReady>()
          .having((s) => s.household.id, 'household.id', _kServerId)
          .having((s) => s.memberCount, 'memberCount', 1)
          .having((s) => s.role, 'role', HouseholdRole.householdOwner),
    );

    await bloc.close();
  });
}

Future<void> _until(
  HouseholdDetailBloc bloc,
  bool Function(HouseholdDetailState) test,
) async {
  if (test(bloc.state)) return;
  await bloc.stream.firstWhere(test).timeout(const Duration(seconds: 5));
}
