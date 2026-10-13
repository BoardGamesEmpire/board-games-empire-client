import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';

import 'package:household/household.dart';

class MockHouseholdRepository extends Mock implements HouseholdRepository {}

class MockSyncOperationSender extends Mock implements SyncOperationSender {}

Household _household({String id = 'hh_local', bool localOnly = true}) =>
    Household(
      id: id,
      name: 'HQ',
      isDirty: localOnly,
      isLocalOnly: localOnly,
      createdAt: DateTime.utc(2024, 1, 15),
      updatedAt: DateTime.utc(2024, 1, 15),
    );

/// What the repository hands back for a create: the optimistic row, the
/// entry it queued, and the op as queued.
typedef _Draft = ({
  Household household,
  String syncQueueId,
  CreateHouseholdOperation operation,
});

_Draft _draft() => (
  household: _household(),
  syncQueueId: 'q1',
  operation: const CreateHouseholdOperation(localId: 'hh_local', name: 'HQ'),
);

/// The op the bloc hands the sender, as the queue entry it names carries it.
CreateHouseholdOperation _sentOp(
  MockSyncOperationSender sender, {
  String entryId = 'q1',
}) =>
    verify(() => sender.deliver(entryId, captureAny())).captured.single
        as CreateHouseholdOperation;

void main() {
  late MockHouseholdRepository repo;
  late MockSyncOperationSender sender;

  setUpAll(() {
    registerFallbackValue(
      const CreateHouseholdOperation(localId: 'x', name: 'x'),
    );
  });

  setUp(() {
    repo = MockHouseholdRepository();
    sender = MockSyncOperationSender();

    when(
      () => repo.create(
        name: any(named: 'name'),
        description: any(named: 'description'),
      ),
    ).thenAnswer((_) async => _draft());

    // The common case: the sender delivers it, and the row moves onto the
    // server's id.
    when(() => sender.deliver(any(), any()))
        .thenAnswer((_) async => const SyncDelivered(householdId: 'hh_server'));
  });

  CreateHouseholdBloc build() =>
      CreateHouseholdBloc(repository: repo, sender: sender);

  void stubDelivery(SyncDelivery delivery) {
    when(() => sender.deliver(any(), any())).thenAnswer((_) async => delivery);
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
      'a delivered create -> Submitting then Success(pendingSync:false) under '
      'the canonical id',
      build: build,
      act: (bloc) => bloc.add(const CreateHouseholdSubmitted(name: 'HQ')),
      expect: () => [
        isA<CreateHouseholdSubmitting>(),
        isA<CreateHouseholdSuccess>()
            .having((s) => s.householdId, 'householdId', 'hh_server')
            .having((s) => s.pendingSync, 'pendingSync', isFalse),
      ],
      verify: (_) => expect(_sentOp(sender).localId, 'hh_local'),
    );

    // Every outcome short of a delivery leaves the household written and
    // queued, so the create succeeded locally and only `pendingSync` says
    // otherwise. What the sender did with the entry is its own concern.
    for (final (name, delivery) in <(String, SyncDelivery)>[
      ('held by another sender', const SyncNotClaimed()),
      ('parked', SyncParked(Exception('rejected'))),
      (
        'handed back',
        SyncFailed(SyncFailure.unreachable, Exception('offline')),
      ),
      ('counted', SyncFailed(SyncFailure.serverError, Exception('503'))),
      (
        'a client fault',
        SyncFailed(SyncFailure.invalidOp, ArgumentError('clientRequestId')),
      ),
    ]) {
      blocTest<CreateHouseholdBloc, CreateHouseholdState>(
        '$name -> Success(pendingSync:true) under the local id',
        setUp: () => stubDelivery(delivery),
        build: build,
        act: (bloc) => bloc.add(const CreateHouseholdSubmitted(name: 'HQ')),
        expect: () => [
          isA<CreateHouseholdSubmitting>(),
          isA<CreateHouseholdSuccess>()
              .having((s) => s.householdId, 'householdId', 'hh_local')
              .having((s) => s.pendingSync, 'pendingSync', isTrue),
        ],
      );
    }

    // The claim is the one thing the sender lets throw (a queue disposed with
    // its session). The household is written and queued all the same, so it
    // must not strand the bloc in Submitting, where the guard drops every
    // resubmit.
    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'a delivery that throws -> Success(pendingSync:true), not stuck in '
      'Submitting',
      setUp: () {
        when(() => sender.deliver(any(), any()))
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
      'local create failure -> Submitting then Failure, nothing delivered',
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
      verify: (_) => verifyNever(() => sender.deliver(any(), any())),
    );

    // The op goes out as the repository queued it, under the entry it
    // names: the fields a drain would send on a retry, including the ones
    // the row has no column for, and the same key, the optimistic row's id,
    // so a lost response here can't become a second household (#131).
    late _Draft queued;
    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'sends the op the repository queued, under the entry it names, '
      'whatever was submitted',
      setUp: () {
        queued = (
          household: _household(id: 'hh_local_7f3k'),
          syncQueueId: 'q7',
          operation: const CreateHouseholdOperation(
            localId: 'hh_local_7f3k',
            name: 'HQ',
            description: 'Fridays',
            language: 'en-GB',
            visibility: 'Friends',
          ),
        );
        when(
          () => repo.create(
            name: any(named: 'name'),
            description: any(named: 'description'),
          ),
        ).thenAnswer((_) async => queued);
      },
      build: build,
      act: (bloc) => bloc.add(
        const CreateHouseholdSubmitted(
          name: '  HQ  ',
          description: ' Fridays ',
        ),
      ),
      verify: (_) {
        // The repository takes the raw values (it does the trimming)...
        verify(() => repo.create(name: '  HQ  ', description: ' Fridays '))
            .called(1);
        // ...and what goes out is its op, not one rebuilt from either.
        expect(_sentOp(sender, entryId: 'q7'), same(queued.operation));
      },
    );

    // #132: the re-entrancy guard in _onSubmitted. The disabled submit
    // button is a *different* defense living in the form; this covers the
    // bloc's own, which is what protects the keyboard "done" path and any
    // future caller that dispatches the event directly.
    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'a second submit while one is in flight is dropped: one Submitting, '
      'one local write, one delivery',
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
        verify(() => sender.deliver(any(), any())).called(1);
      },
    );

    // #132: the guard must not latch. A failure returns the bloc to a
    // non-Submitting state, so the user's retry has to be accepted — the
    // screen keeps the form mounted precisely so they can retry.
    blocTest<CreateHouseholdBloc, CreateHouseholdState>(
      'a retry after a local failure is accepted (the guard does not latch)',
      setUp: () {
        var attempt = 0;
        when(
          () => repo.create(
            name: any(named: 'name'),
            description: any(named: 'description'),
          ),
        ).thenAnswer((_) async {
          attempt++;
          if (attempt == 1) throw StateError('db is down');
          return _draft();
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
