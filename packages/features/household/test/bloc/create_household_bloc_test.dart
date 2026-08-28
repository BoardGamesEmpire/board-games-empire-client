import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:interfaces/repositories.dart';
import 'package:network_interface/network_interface.dart';

import 'package:household/household.dart';

class MockHouseholdRepository extends Mock implements HouseholdRepository {}

class MockHouseholdRemoteDataSource extends Mock
    implements HouseholdRemoteDataSource {}

Household _household({String id = 'hh_local', bool localOnly = true}) =>
    Household(
      id: id,
      name: 'HQ',
      isDirty: localOnly,
      isLocalOnly: localOnly,
      createdAt: DateTime.utc(2024, 1, 15),
      updatedAt: DateTime.utc(2024, 1, 15),
    );

void main() {
  late MockHouseholdRepository repo;
  late MockHouseholdRemoteDataSource remote;

  setUpAll(() {
    registerFallbackValue(_household());
  });

  setUp(() {
    repo = MockHouseholdRepository();
    remote = MockHouseholdRemoteDataSource();

    when(
      () => repo.create(
        name: any(named: 'name'),
        description: any(named: 'description'),
      ),
    ).thenAnswer((_) async => (household: _household(), syncQueueId: 'q1'));

    when(
      () => repo.reconcileCreatedHousehold(
        any(),
        localId: any(named: 'localId'),
        completedSyncQueueId: any(named: 'completedSyncQueueId'),
      ),
    ).thenAnswer((_) async {});
  });

  CreateHouseholdBloc build() =>
      CreateHouseholdBloc(repository: repo, remote: remote);

  /// Stubs a successful inline server send returning the canonical row.
  void stubRemoteSuccess() {
    when(
      () => remote.createHousehold(
        name: any(named: 'name'),
        description: any(named: 'description'),
      ),
    ).thenAnswer((_) async => _household(id: 'hh_server', localOnly: false));
  }

  group('CreateHouseholdBloc', () {
    group('CreateHouseholdFailureCleared', () {
      blocTest<CreateHouseholdBloc, CreateHouseholdState>(
        'retires a spent failure so its banner stops rendering',
        build: build,
        seed: () => const CreateHouseholdFailure(),
        act: (bloc) => bloc.add(const CreateHouseholdFailureCleared()),
        expect: () => [isA<CreateHouseholdInitial>()],
      );

      blocTest<CreateHouseholdBloc, CreateHouseholdState>(
        'is inert while a submit is in flight — an edit must not wipe it',
        build: build,
        seed: () => const CreateHouseholdSubmitting(),
        act: (bloc) => bloc.add(const CreateHouseholdFailureCleared()),
        expect: () => const <CreateHouseholdState>[],
      );
    });

    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'inline sync success -> Submitting then Success(pendingSync:false), '
      'reconciling with the canonical id and the queue id',
      setUp: stubRemoteSuccess,
      build: build,
      act: (bloc) => bloc.add(const CreateHouseholdSubmitted(name: 'HQ')),
      expect: () => [
        isA<CreateHouseholdSubmitting>(),
        isA<CreateHouseholdSuccess>()
            .having((s) => s.householdId, 'householdId', 'hh_server')
            .having((s) => s.pendingSync, 'pendingSync', isFalse),
      ],
      verify: (_) {
        verify(
          () => repo.reconcileCreatedHousehold(
            any(),
            localId: 'hh_local',
            completedSyncQueueId: 'q1',
          ),
        ).called(1);
      },
    );

    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'transient remote failure -> Success(pendingSync:true), no reconcile',
      setUp: () {
        when(
          () => remote.createHousehold(
            name: any(named: 'name'),
            description: any(named: 'description'),
          ),
        ).thenThrow(const HouseholdRemoteTransientException('offline'));
      },
      build: build,
      act: (bloc) => bloc.add(const CreateHouseholdSubmitted(name: 'HQ')),
      expect: () => [
        isA<CreateHouseholdSubmitting>(),
        isA<CreateHouseholdSuccess>()
            .having((s) => s.householdId, 'householdId', 'hh_local')
            .having((s) => s.pendingSync, 'pendingSync', isTrue),
      ],
      verify: (_) {
        verifyNever(
          () => repo.reconcileCreatedHousehold(
            any(),
            localId: any(named: 'localId'),
            completedSyncQueueId: any(named: 'completedSyncQueueId'),
          ),
        );
      },
    );

    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'permanent remote failure -> Success(pendingSync:true) too '
      '(left queued in alpha; #121 owns permanent handling)',
      setUp: () {
        when(
          () => remote.createHousehold(
            name: any(named: 'name'),
            description: any(named: 'description'),
          ),
        ).thenThrow(const HouseholdRemotePermanentException('rejected'));
      },
      build: build,
      act: (bloc) => bloc.add(const CreateHouseholdSubmitted(name: 'HQ')),
      expect: () => [
        isA<CreateHouseholdSubmitting>(),
        isA<CreateHouseholdSuccess>().having(
          (s) => s.pendingSync,
          'pendingSync',
          isTrue,
        ),
      ],
    );

    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'local create failure -> Submitting then Failure, no remote call',
      setUp: () {
        when(
          () => repo.create(
            name: any(named: 'name'),
            description: any(named: 'description'),
          ),
        ).thenThrow(StateError('db is down'));
      },
      build: build,
      act: (bloc) => bloc.add(const CreateHouseholdSubmitted(name: 'HQ')),
      expect: () => [
        isA<CreateHouseholdSubmitting>(),
        isA<CreateHouseholdFailure>(),
      ],
      verify: (_) {
        verifyNever(
          () => remote.createHousehold(
            name: any(named: 'name'),
            description: any(named: 'description'),
          ),
        );
      },
    );

    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'reconcile failure after a successful create -> Success(pendingSync:true) '
      'rather than stranding the bloc in Submitting',
      setUp: () {
        stubRemoteSuccess();
        when(
          () => repo.reconcileCreatedHousehold(
            any(),
            localId: any(named: 'localId'),
            completedSyncQueueId: any(named: 'completedSyncQueueId'),
          ),
        ).thenThrow(StateError('drift boom'));
      },
      build: build,
      act: (bloc) => bloc.add(const CreateHouseholdSubmitted(name: 'HQ')),
      expect: () => [
        isA<CreateHouseholdSubmitting>(),
        isA<CreateHouseholdSuccess>()
            .having((s) => s.householdId, 'householdId', 'hh_local')
            .having((s) => s.pendingSync, 'pendingSync', isTrue),
      ],
    );

    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'sends the repository-canonical (trimmed) name to the remote, '
      'not the raw submitted value',
      setUp: stubRemoteSuccess,
      build: build,
      act: (bloc) => bloc.add(const CreateHouseholdSubmitted(name: '  HQ  ')),
      verify: (_) {
        // Repo receives the raw value (it does the trimming)...
        verify(
          () => repo.create(
            name: '  HQ  ',
            description: any(named: 'description'),
          ),
        ).called(1);
        // ...but the remote gets the canonical trimmed name from the draft.
        verify(
          () => remote.createHousehold(
            name: 'HQ',
            description: any(named: 'description'),
          ),
        ).called(1);
      },
    );

    // #132: the re-entrancy guard in _onSubmitted. The disabled submit
    // button is a *different* defense living in the form; this covers the
    // bloc's own, which is what protects the keyboard "done" path and any
    // future caller that dispatches the event directly.
    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'a second submit while one is in flight is dropped: one Submitting, '
      'one local write, one remote send',
      setUp: stubRemoteSuccess,
      build: build,
      act: (bloc) {
        // The first handler runs synchronously up to its first await (past
        // the guard and the Submitting emit), so the second event is
        // delivered into the Submitting state.
        bloc
          ..add(const CreateHouseholdSubmitted(name: 'HQ'))
          ..add(const CreateHouseholdSubmitted(name: 'HQ'));
      },
      expect: () => [
        isA<CreateHouseholdSubmitting>(),
        isA<CreateHouseholdSuccess>()
            .having((s) => s.householdId, 'householdId', 'hh_server')
            .having((s) => s.pendingSync, 'pendingSync', isFalse),
      ],
      verify: (_) {
        verify(() => repo.create(name: 'HQ', description: null)).called(1);
        verify(() => remote.createHousehold(name: 'HQ', description: null))
            .called(1);
      },
    );

    // #132: the guard must not latch. A failure returns the bloc to a
    // non-Submitting state, so the user's retry has to be accepted — the
    // screen keeps the form mounted precisely so they can retry.
    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'a retry after a local failure is accepted (the guard does not latch)',
      setUp: () {
        stubRemoteSuccess();
        var attempt = 0;
        when(
          () => repo.create(
            name: any(named: 'name'),
            description: any(named: 'description'),
          ),
        ).thenAnswer((_) async {
          attempt++;
          if (attempt == 1) throw StateError('db is down');
          return (household: _household(), syncQueueId: 'q1');
        });
      },
      build: build,
      act: (bloc) async {
        bloc.add(const CreateHouseholdSubmitted(name: 'HQ'));
        // Wait for the terminal failure rather than a bare delay, so the
        // second submit is provably not a re-entrant one.
        await bloc.stream.firstWhere((s) => s is CreateHouseholdFailure);
        bloc.add(const CreateHouseholdSubmitted(name: 'HQ'));
      },
      expect: () => [
        isA<CreateHouseholdSubmitting>(),
        isA<CreateHouseholdFailure>(),
        isA<CreateHouseholdSubmitting>(),
        isA<CreateHouseholdSuccess>()
            .having((s) => s.householdId, 'householdId', 'hh_server')
            .having((s) => s.pendingSync, 'pendingSync', isFalse),
      ],
      verify: (_) {
        verify(() => repo.create(name: 'HQ', description: null)).called(2);
      },
    );
  });
}
