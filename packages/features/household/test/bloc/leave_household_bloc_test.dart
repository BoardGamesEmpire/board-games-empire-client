import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

class MockMemberRemote extends Mock
    implements HouseholdMemberRemoteDataSource {}

class MockHouseholdRepository extends Mock implements HouseholdRepository {}

class MockBgeLogger extends Mock implements BgeLogger {}

final _mine = HouseholdMember(
  id: 'm-me',
  userId: 'u-me',
  householdId: 'h-1',
  role: HouseholdRole.householdMember,
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 1),
);

const _gone = HouseholdMemberRefusedException('gone', statusCode: 404);
const _lastOwner = HouseholdMemberRefusedException('no', statusCode: 400);
const _offline = HouseholdMemberTransientException('down');

/// Named through the package's barrel, which exports the type for
/// [LeaveHouseholdState.failure].
const MemberRequestOutcome _offlineFailure = (
  result: HouseholdMemberActionResult.failed,
  error: _offline,
);

void main() {
  late MockMemberRemote remote;
  late MockHouseholdRepository repository;
  late MockBgeLogger logger;
  late List<String> calls;

  setUp(() {
    remote = MockMemberRemote();
    repository = MockHouseholdRepository();
    logger = MockBgeLogger();
    calls = [];
    when(() => repository.removeCachedMember(any(), any()))
        .thenAnswer((i) async {
          final [h, u] = i.positionalArguments;
          calls.add('removeCachedMember($h, $u)');
        });
  });

  LeaveHouseholdBloc build() => LeaveHouseholdBloc(
    remote: remote,
    repository: repository,
    onChanged: () async => calls.add('onChanged'),
    logger: logger,
  );

  int refreshes() => calls.where((c) => c == 'onChanged').length;

  blocTest<LeaveHouseholdBloc, LeaveHouseholdState>(
    'a 200 goes sending, leaving, left, and removes your own row',
    setUp: () => when(() => remote.leave('h-1')).thenAnswer((_) async => _mine),
    build: build,
    act: (bloc) => bloc.add(const LeaveHouseholdRequested('h-1')),
    expect: () => const [
      LeaveHouseholdState(phase: LeavePhase.sending),
      LeaveHouseholdState(phase: LeavePhase.leaving),
      LeaveHouseholdState(phase: LeavePhase.left),
    ],
    verify: (_) {
      expect(calls, ['removeCachedMember(h-1, u-me)', 'onChanged']);
    },
  );

  test('the page is held from leaving, before the cache write', () async {
    final gate = Completer<void>();
    when(() => remote.leave('h-1')).thenAnswer((_) async => _mine);
    when(() => repository.removeCachedMember(any(), any()))
        .thenAnswer((_) => gate.future);
    final bloc = build();
    addTearDown(bloc.close);

    bloc.add(const LeaveHouseholdRequested('h-1'));
    await pumpEventQueue();

    expect(bloc.state.phase, LeavePhase.leaving);
    expect(bloc.state.busy, isTrue);
    expect(bloc.state.accepted, isTrue);

    gate.complete();
    await pumpEventQueue();
    expect(bloc.state.phase, LeavePhase.left);
  });

  blocTest<LeaveHouseholdBloc, LeaveHouseholdState>(
    'a cache write that throws still ends left',
    setUp: () {
      when(() => remote.leave('h-1')).thenAnswer((_) async => _mine);
      when(() => repository.removeCachedMember(any(), any()))
          .thenThrow(StateError('disk'));
    },
    build: build,
    act: (bloc) => bloc.add(const LeaveHouseholdRequested('h-1')),
    expect: () => const [
      LeaveHouseholdState(phase: LeavePhase.sending),
      LeaveHouseholdState(phase: LeavePhase.leaving),
      LeaveHouseholdState(phase: LeavePhase.left),
    ],
    verify: (_) => expect(refreshes(), 1),
  );

  blocTest<LeaveHouseholdBloc, LeaveHouseholdState>(
    'an enveloped 404 is a gone failure, and refreshes',
    setUp: () => when(() => remote.leave('h-1')).thenThrow(_gone),
    build: build,
    act: (bloc) => bloc.add(const LeaveHouseholdRequested('h-1')),
    expect: () => const [
      LeaveHouseholdState(phase: LeavePhase.sending),
      LeaveHouseholdState(
        failure: (result: HouseholdMemberActionResult.gone, error: _gone),
      ),
    ],
    verify: (_) => expect(calls, ['onChanged']),
  );

  blocTest<LeaveHouseholdBloc, LeaveHouseholdState>(
    'an enveloped 400 is a refused failure with statusCode 400',
    setUp: () => when(() => remote.leave('h-1')).thenThrow(_lastOwner),
    build: build,
    act: (bloc) => bloc.add(const LeaveHouseholdRequested('h-1')),
    expect: () => [
      const LeaveHouseholdState(phase: LeavePhase.sending),
      isA<LeaveHouseholdState>()
          .having((s) => s.phase, 'phase', LeavePhase.idle)
          .having(
            (s) => s.failure?.result,
            'result',
            HouseholdMemberActionResult.refused,
          )
          .having(
            (s) => (s.failure?.error as HouseholdMemberRemoteException?)
                ?.statusCode,
            'statusCode',
            400,
          ),
    ],
  );

  blocTest<LeaveHouseholdBloc, LeaveHouseholdState>(
    'a transient failure ends idle with a failed failure and no refresh',
    setUp: () => when(() => remote.leave('h-1')).thenThrow(_offline),
    build: build,
    act: (bloc) => bloc.add(const LeaveHouseholdRequested('h-1')),
    expect: () => const [
      LeaveHouseholdState(phase: LeavePhase.sending),
      LeaveHouseholdState(
        failure: (result: HouseholdMemberActionResult.failed, error: _offline),
      ),
    ],
    verify: (_) => expect(calls, isEmpty),
  );

  blocTest<LeaveHouseholdBloc, LeaveHouseholdState>(
    'a retry after a failure sends without the failure, and a 200 ends left',
    setUp: () {
      var attempts = 0;
      when(() => remote.leave('h-1')).thenAnswer((_) async {
        if (attempts++ == 0) throw _offline;
        return _mine;
      });
    },
    build: build,
    act: (bloc) async {
      bloc.add(const LeaveHouseholdRequested('h-1'));
      await pumpEventQueue();
      bloc.add(const LeaveHouseholdRequested('h-1'));
    },
    expect: () => const [
      LeaveHouseholdState(phase: LeavePhase.sending),
      LeaveHouseholdState(failure: _offlineFailure),
      // The second request's sending carries no failure: the last one
      // described the first request.
      LeaveHouseholdState(phase: LeavePhase.sending),
      LeaveHouseholdState(phase: LeavePhase.leaving),
      LeaveHouseholdState(phase: LeavePhase.left),
    ],
    verify: (_) {
      verify(() => remote.leave('h-1')).called(2);
      expect(calls, ['removeCachedMember(h-1, u-me)', 'onChanged']);
    },
  );

  test('a second request while sending is dropped', () async {
    final gate = Completer<HouseholdMember>();
    when(() => remote.leave('h-1')).thenAnswer((_) => gate.future);
    final bloc = build();
    addTearDown(bloc.close);

    bloc
      ..add(const LeaveHouseholdRequested('h-1'))
      ..add(const LeaveHouseholdRequested('h-1'));
    await pumpEventQueue();
    gate.complete(_mine);
    await pumpEventQueue();

    expect(bloc.state.phase, LeavePhase.left);
    // A request once left is dropped too.
    bloc.add(const LeaveHouseholdRequested('h-1'));
    await pumpEventQueue();

    verify(() => remote.leave('h-1')).called(1);
  });

  blocTest<LeaveHouseholdBloc, LeaveHouseholdState>(
    'dismissing a failure clears it',
    setUp: () => when(() => remote.leave('h-1')).thenThrow(_lastOwner),
    build: build,
    act: (bloc) async {
      bloc.add(const LeaveHouseholdRequested('h-1'));
      await pumpEventQueue();
      bloc.add(const LeaveHouseholdFailureDismissed());
    },
    skip: 2,
    expect: () => const [LeaveHouseholdState()],
  );
}
