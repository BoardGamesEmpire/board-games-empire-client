import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

class _MockGameCollectionRepository extends Mock
    implements GameCollectionRepository {}

class _MockSyncOperationSender extends Mock implements SyncOperationSender {}

/// The op the repository queued for the add, which the bloc sends.
const _queuedOp = AddToCollectionOperation(
  localId: 'gc_1',
  platformGameId: 'pg_1',
  medium: 'Physical',
  quantity: 3,
);

void main() {
  late _MockGameCollectionRepository repository;
  late _MockSyncOperationSender sender;

  setUpAll(() {
    registerFallbackValue(GameMedium.physical);
    registerFallbackValue(_queuedOp);
  });

  setUp(() {
    repository = _MockGameCollectionRepository();
    sender = _MockSyncOperationSender();
    when(() => sender.deliver(any(), any()))
        .thenAnswer((_) async => const SyncDelivered());
    when(
      () => repository.getCollectionEntry(
        platformGameId: any(named: 'platformGameId'),
        medium: any(named: 'medium'),
      ),
    ).thenAnswer((_) async => null);
  });

  AddToCollectionBloc build() =>
      AddToCollectionBloc(repository: repository, sender: sender);

  GameCollection entry({
    String platformGameId = 'pg_1',
    GameMedium medium = GameMedium.physical,
    int quantity = 2,
  }) => GameCollection(
    id: 'gc_1',
    userId: 'user-a',
    platformGameId: platformGameId,
    medium: medium,
    quantity: quantity,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  );

  void answerLookup(
    GameMedium medium,
    Future<GameCollection?> Function() answer, {
    String platformGameId = 'pg_1',
  }) => when(
    () => repository.getCollectionEntry(
      platformGameId: platformGameId,
      medium: medium,
    ),
  ).thenAnswer((_) => answer());

  /// The user's choice of [medium] on `pg_1`, or on [platformGameId].
  AddToCollectionChoiceChanged choice(
    GameMedium? medium, {
    String platformGameId = 'pg_1',
  }) => AddToCollectionChoiceChanged(
    platformGameId: platformGameId,
    medium: medium,
  );

  /// Answers the add with [answer]'s entry, queued as `sq_1` with
  /// [_queuedOp].
  void answerAdd(Future<GameCollection> Function() answer) =>
      when(
        () => repository.addToCollection(
          platformGameId: any(named: 'platformGameId'),
          medium: any(named: 'medium'),
          quantity: any(named: 'quantity'),
          rating: any(named: 'rating'),
          comment: any(named: 'comment'),
        ),
      ).thenAnswer(
        (_) async =>
            (entry: await answer(), syncQueueId: 'sq_1', operation: _queuedOp),
      );

  void answerSend(Future<SyncDelivery> Function() answer) =>
      when(() => sender.deliver(any(), any())).thenAnswer((_) => answer());

  test('starts editing, with no medium and nothing found', () {
    final bloc = build();
    addTearDown(bloc.close);

    expect(bloc.state, const AddToCollectionState());
    expect(bloc.state.status, AddToCollectionStatus.editing);
  });

  blocTest<AddToCollectionBloc, AddToCollectionState>(
    'choosing a medium finds the entry already in the collection',
    setUp: () => answerLookup(GameMedium.physical, () async => entry()),
    build: build,
    act: (bloc) => bloc.add(choice(GameMedium.physical)),
    expect: () => [
      const AddToCollectionState(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
      ),
      AddToCollectionState(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
        existing: entry(),
      ),
    ],
  );

  blocTest<AddToCollectionBloc, AddToCollectionState>(
    'choosing another medium drops the entry found for the first',
    setUp: () => answerLookup(GameMedium.physical, () async => entry()),
    build: build,
    act: (bloc) async {
      bloc.add(choice(GameMedium.physical));
      await pumpEventQueue();
      bloc.add(choice(GameMedium.digital));
    },
    skip: 2,
    expect: () => [
      const AddToCollectionState(
        platformGameId: 'pg_1',
        medium: GameMedium.digital,
      ),
    ],
  );

  group('a later medium wins over a slow lookup for an earlier one', () {
    late Completer<GameCollection?> physical;

    setUp(() {
      physical = Completer<GameCollection?>();
      answerLookup(GameMedium.physical, () => physical.future);
    });

    blocTest<AddToCollectionBloc, AddToCollectionState>(
      'physical, then digital, then the physical answer',
      build: build,
      act: (bloc) async {
        bloc
          ..add(choice(GameMedium.physical))
          ..add(choice(GameMedium.digital));
        await pumpEventQueue();
        physical.complete(entry());
      },
      expect: () => [
        const AddToCollectionState(
          platformGameId: 'pg_1',
          medium: GameMedium.physical,
        ),
        const AddToCollectionState(
          platformGameId: 'pg_1',
          medium: GameMedium.digital,
        ),
      ],
      verify: (bloc) {
        expect(bloc.state.medium, GameMedium.digital);
        expect(bloc.state.existing, isNull);
      },
    );
  });

  blocTest<AddToCollectionBloc, AddToCollectionState>(
    'a choice looks up the entry on that platform and medium',
    setUp: () => answerLookup(
      GameMedium.digital,
      () async => entry(platformGameId: 'pg_2', medium: GameMedium.digital),
      platformGameId: 'pg_2',
    ),
    build: build,
    act: (bloc) => bloc.add(choice(GameMedium.digital, platformGameId: 'pg_2')),
    expect: () => [
      const AddToCollectionState(
        platformGameId: 'pg_2',
        medium: GameMedium.digital,
      ),
      AddToCollectionState(
        platformGameId: 'pg_2',
        medium: GameMedium.digital,
        existing: entry(platformGameId: 'pg_2', medium: GameMedium.digital),
      ),
    ],
    verify: (_) => verify(
      () => repository.getCollectionEntry(
        platformGameId: 'pg_2',
        medium: GameMedium.digital,
      ),
    ).called(1),
  );

  group('a lookup answering after the platform changed is dropped', () {
    late Completer<GameCollection?> first;

    setUp(() {
      first = Completer<GameCollection?>();
      answerLookup(GameMedium.physical, () => first.future);
    });

    blocTest<AddToCollectionBloc, AddToCollectionState>(
      'physical on pg_1, then physical on pg_2, then the pg_1 answer',
      build: build,
      act: (bloc) async {
        bloc
          ..add(choice(GameMedium.physical))
          ..add(choice(GameMedium.physical, platformGameId: 'pg_2'));
        await pumpEventQueue();
        first.complete(entry());
      },
      expect: () => [
        const AddToCollectionState(
          platformGameId: 'pg_1',
          medium: GameMedium.physical,
        ),
        const AddToCollectionState(
          platformGameId: 'pg_2',
          medium: GameMedium.physical,
        ),
      ],
      verify: (bloc) => expect(bloc.state.existing, isNull),
    );
  });

  blocTest<AddToCollectionBloc, AddToCollectionState>(
    'a choice with no medium clears the existing entry',
    setUp: () => answerLookup(GameMedium.physical, () async => entry()),
    build: build,
    act: (bloc) async {
      bloc.add(choice(GameMedium.physical));
      await pumpEventQueue();
      bloc.add(choice(null, platformGameId: 'pg_2'));
    },
    skip: 2,
    expect: () => [const AddToCollectionState(platformGameId: 'pg_2')],
    // With no medium there is nothing to look up.
    verify: (_) => verify(
      () => repository.getCollectionEntry(
        platformGameId: any(named: 'platformGameId'),
        medium: any(named: 'medium'),
      ),
    ).called(1),
  );

  blocTest<AddToCollectionBloc, AddToCollectionState>(
    'a failed lookup shows no entry, and throws nothing out of the bloc',
    // A disposed session scope's repository throws this.
    setUp: () => answerLookup(
      GameMedium.physical,
      () async => throw StateError('disposed'),
    ),
    build: build,
    act: (bloc) => bloc.add(choice(GameMedium.physical)),
    expect: () => [
      const AddToCollectionState(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
      ),
    ],
    errors: () => isEmpty,
  );

  blocTest<AddToCollectionBloc, AddToCollectionState>(
    'submitting adds and reports the entry',
    setUp: () => answerAdd(() async => entry(quantity: 3)),
    build: build,
    act: (bloc) => bloc.add(
      const AddToCollectionSubmitted(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
        quantity: 3,
        rating: 7,
        comment: 'Great',
      ),
    ),
    expect: () => [
      const AddToCollectionState(status: AddToCollectionStatus.submitting),
      const AddToCollectionState(
        status: AddToCollectionStatus.added,
        sync: CollectionSync.synced,
      ),
    ],
    verify: (_) {
      verify(
        () => repository.addToCollection(
          platformGameId: 'pg_1',
          medium: GameMedium.physical,
          quantity: 3,
          rating: 7,
          comment: 'Great',
        ),
      ).called(1);
      // The op as queued, at once (#45).
      verify(() => sender.deliver('sq_1', _queuedOp)).called(1);
    },
  );

  for (final (outcome, answer, sync)
      in <(String, SyncDelivery, CollectionSync)>[
        (
          'a send that fails leaves it queued',
          const SyncFailed(SyncFailure.unreachable, 'offline'),
          CollectionSync.queued,
        ),
        (
          'a send left for the drain leaves it queued',
          const SyncNotClaimed(),
          CollectionSync.queued,
        ),
        (
          'a send the server refuses is refused',
          const SyncParked('400'),
          CollectionSync.refused,
        ),
      ]) {
    blocTest<AddToCollectionBloc, AddToCollectionState>(
      '$outcome, and the game is still added',
      setUp: () {
        answerAdd(() async => entry(quantity: 3));
        answerSend(() async => answer);
      },
      build: build,
      act: (bloc) => bloc.add(
        const AddToCollectionSubmitted(
          platformGameId: 'pg_1',
          medium: GameMedium.physical,
          quantity: 3,
        ),
      ),
      expect: () => [
        const AddToCollectionState(status: AddToCollectionStatus.submitting),
        AddToCollectionState(status: AddToCollectionStatus.added, sync: sync),
      ],
    );
  }

  blocTest<AddToCollectionBloc, AddToCollectionState>(
    'a claim that throws leaves it queued, and nothing is thrown',
    // A disposed session scope's queue throws this.
    setUp: () {
      answerAdd(() async => entry(quantity: 3));
      answerSend(() async => throw StateError('disposed'));
    },
    build: build,
    act: (bloc) => bloc.add(
      const AddToCollectionSubmitted(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
        quantity: 3,
      ),
    ),
    expect: () => [
      const AddToCollectionState(status: AddToCollectionStatus.submitting),
      const AddToCollectionState(
        status: AddToCollectionStatus.added,
        sync: CollectionSync.queued,
      ),
    ],
    errors: () => isEmpty,
  );

  blocTest<AddToCollectionBloc, AddToCollectionState>(
    'submitting with no rating or comment sends none',
    setUp: () => answerAdd(() async => entry(quantity: 1)),
    build: build,
    act: (bloc) => bloc.add(
      const AddToCollectionSubmitted(
        platformGameId: 'pg_1',
        medium: GameMedium.digital,
        quantity: 1,
      ),
    ),
    verify: (_) => verify(
      () => repository.addToCollection(
        platformGameId: 'pg_1',
        medium: GameMedium.digital,
      ),
    ).called(1),
  );

  blocTest<AddToCollectionBloc, AddToCollectionState>(
    "submit adds on the event's platform game",
    setUp: () => answerAdd(() async => entry(platformGameId: 'pg_2')),
    build: build,
    act: (bloc) async {
      // The choice the bloc last saw is not what decides it.
      bloc.add(choice(GameMedium.physical));
      await pumpEventQueue();
      bloc.add(
        const AddToCollectionSubmitted(
          platformGameId: 'pg_2',
          medium: GameMedium.digital,
          quantity: 1,
        ),
      );
    },
    verify: (_) {
      verify(
        () => repository.addToCollection(
          platformGameId: 'pg_2',
          medium: GameMedium.digital,
        ),
      ).called(1);
      verifyNever(
        () => repository.addToCollection(
          platformGameId: 'pg_1',
          medium: any(named: 'medium'),
          quantity: any(named: 'quantity'),
          rating: any(named: 'rating'),
          comment: any(named: 'comment'),
        ),
      );
    },
  );

  group('a second submit while one is running', () {
    late Completer<GameCollection> add;

    setUp(() {
      add = Completer<GameCollection>();
      answerAdd(() => add.future);
    });

    blocTest<AddToCollectionBloc, AddToCollectionState>(
      'adds once',
      build: build,
      act: (bloc) async {
        const submit = AddToCollectionSubmitted(
          platformGameId: 'pg_1',
          medium: GameMedium.physical,
          quantity: 1,
        );
        bloc.add(submit);
        await pumpEventQueue();
        bloc.add(submit);
        await pumpEventQueue();
        add.complete(entry(quantity: 1));
      },
      expect: () => [
        const AddToCollectionState(status: AddToCollectionStatus.submitting),
        const AddToCollectionState(
          status: AddToCollectionStatus.added,
          sync: CollectionSync.synced,
        ),
      ],
      verify: (_) => verify(
        () => repository.addToCollection(
          platformGameId: any(named: 'platformGameId'),
          medium: any(named: 'medium'),
          quantity: any(named: 'quantity'),
          rating: any(named: 'rating'),
          comment: any(named: 'comment'),
        ),
      ).called(1),
    );
  });

  blocTest<AddToCollectionBloc, AddToCollectionState>(
    'a failed add is a failure, and editing clears it',
    // A disposed session scope's repository throws this.
    setUp: () => answerAdd(() async => throw StateError('disposed')),
    build: build,
    act: (bloc) async {
      bloc.add(
        const AddToCollectionSubmitted(
          platformGameId: 'pg_1',
          medium: GameMedium.physical,
          quantity: 1,
        ),
      );
      await pumpEventQueue();
      bloc.add(const AddToCollectionFailureCleared());
    },
    expect: () => [
      const AddToCollectionState(status: AddToCollectionStatus.submitting),
      const AddToCollectionState(status: AddToCollectionStatus.failed),
      const AddToCollectionState(),
    ],
    errors: () => isEmpty,
    verify: (_) => verifyNever(() => sender.deliver(any(), any())),
  );

  blocTest<AddToCollectionBloc, AddToCollectionState>(
    'editing with no failure shown changes nothing',
    build: build,
    act: (bloc) => bloc.add(const AddToCollectionFailureCleared()),
    expect: () => <AddToCollectionState>[],
  );

  blocTest<AddToCollectionBloc, AddToCollectionState>(
    'a submit keeps the medium and the entry found',
    setUp: () {
      answerLookup(GameMedium.physical, () async => entry());
      answerAdd(() async => entry(quantity: 3));
    },
    build: build,
    act: (bloc) async {
      bloc.add(choice(GameMedium.physical));
      await pumpEventQueue();
      bloc.add(
        const AddToCollectionSubmitted(
          platformGameId: 'pg_1',
          medium: GameMedium.physical,
          quantity: 1,
        ),
      );
    },
    skip: 2,
    expect: () => [
      AddToCollectionState(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
        existing: entry(),
        status: AddToCollectionStatus.submitting,
      ),
      AddToCollectionState(
        platformGameId: 'pg_1',
        medium: GameMedium.physical,
        existing: entry(),
        status: AddToCollectionStatus.added,
        sync: CollectionSync.synced,
      ),
    ],
  );
}
