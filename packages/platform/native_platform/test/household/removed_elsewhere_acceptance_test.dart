import 'dart:async';

import 'package:di/di.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// #268's acceptance, over the real repository and database: what another
/// device changed reaches this one's screens on the next hydrate.
///
/// The hydrator and repository suites each cover their half against the
/// other mocked. This exists for the join between them: the snapshot the
/// hydrator reads, what it reads as purgeable before requesting it, and
/// the rows the repository removes as a result, observed where a user
/// would see them.
class _MockHouseholdRemoteDataSource extends Mock
    implements HouseholdRemoteDataSource {}

const _kUserId = 'user-abc';
const _kOtherUserId = 'user-other';
final _t = DateTime.utc(2024);

Household _household(String id) =>
    Household(id: id, name: 'Household $id', createdAt: _t, updatedAt: _t);

HouseholdMember _member(String householdId, String userId) => HouseholdMember(
  id: 'm-$householdId-$userId',
  userId: userId,
  householdId: householdId,
  role: HouseholdRole.householdMember,
  createdAt: _t,
  updatedAt: _t,
);

/// The whole list in one page, as a user session receives it.
PaginatedResult<HouseholdWithMembers> _snapshot(
  Map<String, List<String>> rosters,
) => PaginatedResult(
  items: [
    for (final MapEntry(key: id, value: users) in rosters.entries)
      (
        household: _household(id),
        members: [for (final user in users) _member(id, user)],
      ),
  ],
  meta: PaginationMeta(
    page: 1,
    limit: 100,
    total: rosters.length,
    totalPages: 1,
    hasMore: false,
  ),
);

void main() {
  late ServerDatabase db;
  late SyncQueueRepositoryImpl syncQueue;
  late HouseholdRepositoryImpl repo;
  late _MockHouseholdRemoteDataSource remote;
  late HouseholdHydrator hydrator;

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
    remote = _MockHouseholdRemoteDataSource();
    hydrator = HouseholdHydrator(repository: repo, remote: remote);
  });

  tearDown(() async {
    await repo.onDispose();
    await syncQueue.onDispose();
    await db.close();
  });

  void serverReturns(Map<String, List<String>> rosters) => when(
    () => remote.fetchHouseholds(
      page: any(named: 'page'),
      limit: any(named: 'limit'),
    ),
  ).thenAnswer((_) async => _snapshot(rosters));

  test('a household I was removed from elsewhere leaves the list', () async {
    serverReturns({
      'h-kept': [_kUserId],
      'h-gone': [_kUserId, _kOtherUserId],
    });
    await hydrator.hydrate();

    final bloc = HouseholdListBloc(repository: repo);
    addTearDown(bloc.close);
    await _untilListed(bloc, (s) => _listed(s).length == 2);

    serverReturns({
      'h-kept': [_kUserId],
    });
    expect(await hydrator.hydrate(), equals(HydrateOutcome.complete));

    await _untilListed(bloc, (s) => _listed(s).length == 1);
    expect(_listed(bloc.state), equals(['h-kept']));
  });

  test('a member removed elsewhere leaves the detail count', () async {
    serverReturns({
      'h-1': [_kUserId, _kOtherUserId],
    });
    await hydrator.hydrate();

    final bloc = HouseholdDetailBloc(householdId: 'h-1', repository: repo);
    addTearDown(bloc.close);
    await _untilDetail(bloc, (s) => _memberCount(s) == 2);

    serverReturns({
      'h-1': [_kUserId],
    });
    await hydrator.hydrate();

    await _untilDetail(bloc, (s) => _memberCount(s) == 1);
  });

  test('a household created while a pass is in flight survives it', () async {
    // The inline create path: the user creates a household, the server
    // confirms it and the reconcile lands, all while a hydrate's request
    // is out. That snapshot predates the household, so it lacks it.
    final response = Completer<PaginatedResult<HouseholdWithMembers>>();
    when(
      () => remote.fetchHouseholds(
        page: any(named: 'page'),
        limit: any(named: 'limit'),
      ),
    ).thenAnswer((_) => response.future);

    final pass = hydrator.hydrate();
    final created = await repo.create(name: 'Just made');
    await repo.reconcileCreatedHousehold(
      created.household.copyWith(
        id: 'h-server',
        isDirty: false,
        isLocalOnly: false,
      ),
      localId: created.household.id,
      completedSyncQueueId: created.syncQueueId,
    );
    response.complete(_snapshot(const {}));

    expect(await pass, equals(HydrateOutcome.complete));
    final listed = await repo.getHouseholds();
    expect(listed.map((h) => h.id), equals(['h-server']));
  });
}

List<String> _listed(HouseholdListState state) => switch (state) {
  HouseholdListReady(:final households) => [for (final h in households) h.id],
  _ => const [],
};

int? _memberCount(HouseholdDetailState state) => switch (state) {
  HouseholdDetailReady(:final memberCount) => memberCount,
  _ => null,
};

Future<void> _untilListed(
  HouseholdListBloc bloc,
  bool Function(HouseholdListState) test,
) async {
  if (test(bloc.state)) return;
  await bloc.stream.firstWhere(test).timeout(const Duration(seconds: 5));
}

Future<void> _untilDetail(
  HouseholdDetailBloc bloc,
  bool Function(HouseholdDetailState) test,
) async {
  if (test(bloc.state)) return;
  await bloc.stream.firstWhere(test).timeout(const Duration(seconds: 5));
}
