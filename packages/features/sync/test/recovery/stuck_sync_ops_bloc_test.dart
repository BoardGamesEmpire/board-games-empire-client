import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:sync_queue/sync_queue.dart';

class _MockRecovery extends Mock implements SyncRecovery {}

const _add = StuckSyncOp(
  entryId: 'q1',
  kind: StuckSyncOpKind.addToCollection,
  subject: 'Brass',
);
const _create = StuckSyncOp(
  entryId: 'q2',
  kind: StuckSyncOpKind.createHousehold,
  subject: 'Smiths',
);

void main() {
  late _MockRecovery recovery;
  late StreamController<List<StuckSyncOp>> stuck;

  setUp(() {
    recovery = _MockRecovery();
    stuck = StreamController<List<StuckSyncOp>>();
    when(() => recovery.watch()).thenAnswer((_) => stuck.stream);
  });

  tearDown(() => stuck.close());

  StuckSyncOpsBloc build() => StuckSyncOpsBloc(recovery: recovery);

  blocTest<StuckSyncOpsBloc, StuckSyncOpsState>(
    'lists what the recovery watches, as it changes',
    build: build,
    act: (_) async {
      stuck.add([_add, _create]);
      await pumpEventQueue();
      stuck.add([_create]);
    },
    expect: () => [
      const StuckSyncOpsReady([_add, _create]),
      const StuckSyncOpsReady([_create]),
    ],
  );

  blocTest<StuckSyncOpsBloc, StuckSyncOpsState>(
    'a failed read shows the error',
    build: build,
    act: (_) => stuck.addError(StateError('read failed')),
    expect: () => [const StuckSyncOpsError()],
  );

  group('retry', () {
    blocTest<StuckSyncOpsBloc, StuckSyncOpsState>(
      'marks the op busy while it runs',
      setUp: () {
        when(() => recovery.retry('q1')).thenAnswer((_) async => true);
      },
      build: build,
      act: (bloc) async {
        stuck.add([_add]);
        await pumpEventQueue();
        bloc.add(const StuckSyncOpsRetryRequested('q1'));
      },
      expect: () => [
        const StuckSyncOpsReady([_add]),
        const StuckSyncOpsReady([_add], busy: {'q1'}),
        const StuckSyncOpsReady([_add]),
      ],
      verify: (_) => verify(() => recovery.retry('q1')).called(1),
    );

    blocTest<StuckSyncOpsBloc, StuckSyncOpsState>(
      'that throws says so, and frees the op',
      setUp: () {
        when(() => recovery.retry('q1')).thenThrow(StateError('disposed'));
      },
      build: build,
      act: (bloc) async {
        stuck.add([_add]);
        await pumpEventQueue();
        bloc.add(const StuckSyncOpsRetryRequested('q1'));
      },
      expect: () => [
        const StuckSyncOpsReady([_add]),
        const StuckSyncOpsReady([_add], busy: {'q1'}),
        const StuckSyncOpsReady([
          _add,
        ], problem: StuckSyncOpsProblem.actionFailed),
      ],
    );

    blocTest<StuckSyncOpsBloc, StuckSyncOpsState>(
      'that the server refuses again says so',
      setUp: () {
        when(() => recovery.retry('q1')).thenAnswer((_) async => false);
      },
      build: build,
      act: (bloc) async {
        stuck.add([_add]);
        await pumpEventQueue();
        bloc.add(const StuckSyncOpsRetryRequested('q1'));
      },
      expect: () => [
        const StuckSyncOpsReady([_add]),
        const StuckSyncOpsReady([_add], busy: {'q1'}),
        const StuckSyncOpsReady([
          _add,
        ], problem: StuckSyncOpsProblem.refusedAgain),
      ],
    );

    blocTest<StuckSyncOpsBloc, StuckSyncOpsState>(
      'is ignored for an op already busy',
      setUp: () {
        final never = Completer<bool>();
        when(() => recovery.retry('q1')).thenAnswer((_) => never.future);
      },
      build: build,
      act: (bloc) async {
        stuck.add([_add]);
        await pumpEventQueue();
        bloc
          ..add(const StuckSyncOpsRetryRequested('q1'))
          ..add(const StuckSyncOpsDiscardRequested('q1'));
      },
      expect: () => [
        const StuckSyncOpsReady([_add]),
        const StuckSyncOpsReady([_add], busy: {'q1'}),
      ],
      verify: (_) => verifyNever(() => recovery.discard(any())),
    );
  });

  group('discard', () {
    blocTest<StuckSyncOpsBloc, StuckSyncOpsState>(
      'discards through the recovery, clearing an earlier failure',
      setUp: () {
        when(() => recovery.retry('q1')).thenThrow(StateError('disposed'));
        when(() => recovery.discard('q2')).thenAnswer((_) async {});
      },
      build: build,
      act: (bloc) async {
        stuck.add([_add, _create]);
        await pumpEventQueue();
        bloc.add(const StuckSyncOpsRetryRequested('q1'));
        await pumpEventQueue();
        bloc.add(const StuckSyncOpsDiscardRequested('q2'));
      },
      skip: 3,
      expect: () => [
        const StuckSyncOpsReady([_add, _create], busy: {'q2'}),
        const StuckSyncOpsReady([_add, _create]),
      ],
      verify: (_) => verify(() => recovery.discard('q2')).called(1),
    );
  });
}
