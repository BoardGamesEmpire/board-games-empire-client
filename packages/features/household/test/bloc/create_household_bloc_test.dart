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

class MockSyncQueueRepository extends Mock implements SyncQueueRepository {}

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
  late MockSyncQueueRepository syncQueue;

  setUpAll(() {
    registerFallbackValue(_household());
  });

  setUp(() {
    repo = MockHouseholdRepository();
    remote = MockHouseholdRemoteDataSource();
    syncQueue = MockSyncQueueRepository();

    // The inline send claims the op it just queued (#430). The default is
    // the common case: nothing else holds it.
    when(() => syncQueue.claim(any())).thenAnswer((_) async => true);
    when(() => syncQueue.release(any())).thenAnswer((_) async {});
    when(() => syncQueue.markFailed(any(), error: any(named: 'error')))
        .thenAnswer((_) async {});

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

  CreateHouseholdBloc build() => CreateHouseholdBloc(
    repository: repo,
    remote: remote,
    syncQueue: syncQueue,
  );

  void verifyNoQueueWrite() {
    verifyNever(() => syncQueue.markFailed(any(), error: any(named: 'error')));
    verifyNever(() => syncQueue.release(any()));
  }

  void verifyNoSend() {
    verifyNever(
      () => remote.createHousehold(
        name: any(named: 'name'),
        clientRequestId: any(named: 'clientRequestId'),
        description: any(named: 'description'),
      ),
    );
  }

  /// Stubs a successful inline server send returning the canonical row.
  void stubRemoteSuccess() {
    when(
      () => remote.createHousehold(
        name: any(named: 'name'),
        clientRequestId: any(named: 'clientRequestId'),
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
        verifyInOrder([
          () => syncQueue.claim('q1'),
          () => remote.createHousehold(
            name: any(named: 'name'),
            clientRequestId: any(named: 'clientRequestId'),
            description: any(named: 'description'),
          ),
          () => repo.reconcileCreatedHousehold(
            any(),
            localId: 'hh_local',
            completedSyncQueueId: 'q1',
          ),
        ]);
        verifyNoQueueWrite();
      },
    );

    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'transient remote failure -> Success(pendingSync:true), no reconcile',
      setUp: () {
        when(
          () => remote.createHousehold(
            name: any(named: 'name'),
            clientRequestId: any(named: 'clientRequestId'),
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
        // A real attempt that failed: counted, with its error (#430).
        verify(
          () => syncQueue.markFailed(
            'q1',
            error: any(named: 'error', that: contains('offline')),
          ),
        ).called(1);
        verifyNever(() => syncQueue.release(any()));
      },
    );

    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'permanent remote failure -> Success(pendingSync:true) too '
      '(left queued in alpha; #121 owns permanent handling)',
      setUp: () {
        when(
          () => remote.createHousehold(
            name: any(named: 'name'),
            clientRequestId: any(named: 'clientRequestId'),
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
      verify: (_) {
        verify(
          () => syncQueue.markFailed(
            'q1',
            error: any(named: 'error', that: contains('rejected')),
          ),
        ).called(1);
        verifyNever(() => syncQueue.release(any()));
      },
    );

    // The remote refuses a key the server would reject before any request
    // (#131). The household is already written and queued, so that must not
    // strand the bloc in Submitting, where the guard drops every resubmit.
    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'an error thrown before the request -> Success(pendingSync:true), '
      'not stuck in Submitting',
      setUp: () {
        when(
          () => remote.createHousehold(
            name: any(named: 'name'),
            clientRequestId: any(named: 'clientRequestId'),
            description: any(named: 'description'),
          ),
        ).thenThrow(ArgumentError.value('', 'clientRequestId'));
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
        // A client fault, not an attempt: handed back uncounted (#430).
        verify(() => syncQueue.release('q1')).called(1);
        verifyNever(
          () => syncQueue.markFailed(any(), error: any(named: 'error')),
        );
      },
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
        verifyNoSend();
        verifyNever(() => syncQueue.claim(any()));
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
      verify: (_) {
        // The server did its part, and the key dedupes the retry (#131):
        // handed back uncounted, not failed (#430).
        verify(() => syncQueue.release('q1')).called(1);
        verifyNever(
          () => syncQueue.markFailed(any(), error: any(named: 'error')),
        );
      },
    );

    // #430: a drain (or another tab) can claim the op between the local
    // create and the inline send. Then it is theirs to deliver.
    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'a lost claim -> Success(pendingSync:true) without sending',
      setUp: () {
        stubRemoteSuccess();
        when(() => syncQueue.claim(any())).thenAnswer((_) async => false);
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
        verifyNoSend();
        verifyNoQueueWrite();
      },
    );

    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'a claim that throws -> Success(pendingSync:true) without sending',
      setUp: () {
        stubRemoteSuccess();
        when(() => syncQueue.claim(any())).thenThrow(StateError('disposed'));
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
        verifyNoSend();
        verifyNoQueueWrite();
      },
    );

    // Recording the failure is bookkeeping: if it throws (the session's
    // scope popped mid-send, say), the household is still written and
    // queued, and the screen must still leave Submitting.
    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'a failure write that throws still ends in Success(pendingSync:true)',
      setUp: () {
        when(
          () => remote.createHousehold(
            name: any(named: 'name'),
            clientRequestId: any(named: 'clientRequestId'),
            description: any(named: 'description'),
          ),
        ).thenThrow(const HouseholdRemoteTransientException('offline'));
        when(() => syncQueue.markFailed(any(), error: any(named: 'error')))
            .thenThrow(StateError('disposed'));
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
            clientRequestId: any(named: 'clientRequestId'),
            description: any(named: 'description'),
          ),
        ).called(1);
      },
    );

    // #131: the key makes a retry of this create idempotent server-side, so it
    // must be the optimistic row's id. That is the queued op's localId, which
    // the drain (#121) will send on its retry; a fresh value would let a lost
    // response here become a second household.
    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      "sends the optimistic row's id as the idempotency key",
      setUp: () {
        stubRemoteSuccess();
        when(
          () => repo.create(
            name: any(named: 'name'),
            description: any(named: 'description'),
          ),
        ).thenAnswer(
          (_) async =>
              (household: _household(id: 'hh_local_7f3k'), syncQueueId: 'q1'),
        );
      },
      build: build,
      act: (bloc) => bloc.add(const CreateHouseholdSubmitted(name: 'HQ')),
      verify: (_) {
        verify(
          () => remote.createHousehold(
            name: any(named: 'name'),
            clientRequestId: 'hh_local_7f3k',
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
        verify(
          () => remote.createHousehold(
            name: 'HQ',
            clientRequestId: any(named: 'clientRequestId'),
            description: null,
          ),
        ).called(1);
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
