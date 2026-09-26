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
/// renders it too.
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
}

Future<void> _until(
  HouseholdDetailBloc bloc,
  bool Function(HouseholdDetailState) test,
) async {
  if (test(bloc.state)) return;
  await bloc.stream.firstWhere(test).timeout(const Duration(seconds: 5));
}
