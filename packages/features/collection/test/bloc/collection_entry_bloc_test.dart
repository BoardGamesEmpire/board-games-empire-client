import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_collection/game_collection.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/sync.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

import '../support/list_items.dart';

class _MockGameCollectionRepository extends Mock
    implements GameCollectionRepository {}

class _MockSyncOperationSender extends Mock implements SyncOperationSender {}

class _MockLogger extends Mock implements BgeLogger {}

const _updateOp = UpdateCollectionOperation(collectionId: 'gc_1', quantity: 3);
const _removeOp = RemoveFromCollectionOperation(collectionId: 'gc_1');

void main() {
  late _MockGameCollectionRepository repository;
  late _MockSyncOperationSender sender;
  late _MockLogger logger;
  late StreamController<GameCollectionListItem?> watch;

  setUpAll(() {
    registerFallbackValue(_updateOp);
    registerFallbackValue(StackTrace.empty);
  });

  setUp(() {
    repository = _MockGameCollectionRepository();
    sender = _MockSyncOperationSender();
    logger = _MockLogger();
    watch = StreamController<GameCollectionListItem?>();
    addTearDown(watch.close);
    when(() => repository.watchCollectionListItem('gc_1'))
        .thenAnswer((_) => watch.stream);
    when(() => sender.deliver(any(), any()))
        .thenAnswer((_) async => const SyncDelivered());
  });

  CollectionEntryBloc build() => CollectionEntryBloc(
    repository: repository,
    sender: sender,
    entryId: 'gc_1',
    logger: logger,
  );

  /// The entry the edit tests start from: quantity 2, rating 7, comment 'ok',
  /// favorite null, play again true.
  GameCollectionListItem row({int quantity = 2}) {
    final base = listItem('gc_1', quantity: quantity);
    return GameCollectionListItem(
      entry: base.entry.copyWith(rating: 7, comment: 'ok', playAgain: true),
      gameId: base.gameId,
      title: base.title,
      subtitle: base.subtitle,
      platformName: base.platformName,
      thumbnail: base.thumbnail,
    );
  }

  CollectionEntryState ready(
    GameCollectionListItem item, {
    CollectionEntryAction action = CollectionEntryAction.idle,
    CollectionSync? sync,
    bool changed = true,
  }) => CollectionEntryState(
    view: CollectionEntryView.ready,
    item: item,
    action: action,
    sync: sync,
    changed: changed,
  );

  void answerUpdate() =>
      when(
        () => repository.updateCollectionEntry(
          id: any(named: 'id'),
          quantity: any(named: 'quantity'),
          rating: any(named: 'rating'),
          playAgain: any(named: 'playAgain'),
          favorite: any(named: 'favorite'),
          comment: any(named: 'comment'),
        ),
      ).thenAnswer(
        (_) async =>
            (entry: row().entry, syncQueueId: 'sq_1', operation: _updateOp),
      );

  Future<
    ({
      GameCollection entry,
      String syncQueueId,
      UpdateCollectionOperation operation,
    })
  >
  callUpdate() => repository.updateCollectionEntry(
    id: any(named: 'id'),
    quantity: any(named: 'quantity'),
    rating: any(named: 'rating'),
    playAgain: any(named: 'playAgain'),
    favorite: any(named: 'favorite'),
    comment: any(named: 'comment'),
  );

  void verifyNoUpdate() => verifyNever(callUpdate);

  void verifyNoSend() => verifyNever(() => sender.deliver(any(), any()));

  /// The edit sheet's submit, from a sheet opened on [base] (the entry
  /// [row] gives, by default).
  CollectionEntryEditSubmitted edit({
    int quantity = 2,
    int? rating = 7,
    String? comment = 'ok',
    bool favorite = false,
    bool playAgain = true,
    GameCollection? base,
  }) => CollectionEntryEditSubmitted(
    base: base ?? row().entry,
    quantity: quantity,
    rating: rating,
    comment: comment,
    favorite: favorite,
    playAgain: playAgain,
  );

  /// Waits for the watch's row to reach the bloc.
  Future<void> show(
    CollectionEntryBloc bloc,
    GameCollectionListItem? item,
  ) async {
    watch.add(item);
    await pumpEventQueue();
  }

  test('starts loading', () {
    final bloc = build();
    addTearDown(bloc.close);

    expect(bloc.state, const CollectionEntryState());
  });

  blocTest<CollectionEntryBloc, CollectionEntryState>(
    'the first row makes it ready',
    build: build,
    act: (bloc) => watch.add(row()),
    expect: () => [ready(row())],
  );

  blocTest<CollectionEntryBloc, CollectionEntryState>(
    'a null from the watch is gone, and keeps the last item',
    build: build,
    act: (bloc) async {
      await show(bloc, row());
      await show(bloc, null);
    },
    expect: () => [
      ready(row()),
      CollectionEntryState(view: CollectionEntryView.gone, item: row()),
    ],
  );

  blocTest<CollectionEntryBloc, CollectionEntryState>(
    'a null before any row is gone with no item',
    build: build,
    act: (bloc) => watch.add(null),
    expect: () => [const CollectionEntryState(view: CollectionEntryView.gone)],
  );

  blocTest<CollectionEntryBloc, CollectionEntryState>(
    'a row after gone is ready again',
    build: build,
    act: (bloc) async {
      await show(bloc, row());
      await show(bloc, null);
      await show(bloc, row(quantity: 5));
    },
    skip: 2,
    expect: () => [ready(row(quantity: 5))],
  );

  blocTest<CollectionEntryBloc, CollectionEntryState>(
    'a watch error is error, logged, and keeps the item',
    build: build,
    act: (bloc) async {
      await show(bloc, row());
      watch.addError(StateError('boom'));
      await pumpEventQueue();
    },
    skip: 1,
    expect: () => [
      CollectionEntryState(view: CollectionEntryView.error, item: row()),
    ],
    verify: (_) => verify(
      () => logger.warn(
        any(),
        error: any(named: 'error'),
        stackTrace: any(named: 'stackTrace'),
      ),
    ).called(1),
  );

  blocTest<CollectionEntryBloc, CollectionEntryState>(
    'a row after an error is ready again',
    build: build,
    act: (bloc) async {
      await show(bloc, row());
      watch.addError(StateError('boom'));
      await pumpEventQueue();
      await show(bloc, row(quantity: 4));
    },
    skip: 2,
    expect: () => [ready(row(quantity: 4))],
  );

  group('an edit', () {
    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'sends only the fields that changed',
      setUp: answerUpdate,
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(edit(quantity: 3));
      },
      skip: 1,
      expect: () => [
        ready(row(), action: CollectionEntryAction.saving),
        ready(
          row(),
          action: CollectionEntryAction.saved,
          sync: CollectionSync.synced,
        ),
      ],
      verify: (_) {
        verify(
          () => repository.updateCollectionEntry(
            id: 'gc_1',
            quantity: 3,
          ),
        ).called(1);
        verify(() => sender.deliver('sq_1', _updateOp)).called(1);
      },
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'sends a changed rating, comment, favorite and play again',
      setUp: answerUpdate,
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(
          edit(rating: 9, comment: ' fine ', favorite: true, playAgain: false),
        );
      },
      verify: (_) => verify(
        () => repository.updateCollectionEntry(
          id: 'gc_1',
          rating: 9,
          playAgain: false,
          favorite: true,
          comment: 'fine',
        ),
      ).called(1),
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'that changes nothing makes no call',
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(edit(comment: 'ok  ', rating: null));
      },
      skip: 1,
      expect: () => [
        ready(row(), action: CollectionEntryAction.saved, changed: false),
      ],
      verify: (_) {
        verifyNoUpdate();
        verifyNoSend();
      },
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'with a blank comment on an entry with none is unchanged',
      build: build,
      act: (bloc) async {
        final base = listItem('gc_1');
        await show(bloc, base);
        bloc.add(
          CollectionEntryEditSubmitted(
            base: base.entry,
            quantity: 1,
            comment: '   ',
            favorite: false,
            playAgain: false,
          ),
        );
      },
      skip: 1,
      expect: () => [
        ready(
          listItem('gc_1'),
          action: CollectionEntryAction.saved,
          changed: false,
        ),
      ],
      verify: (_) {
        verifyNoUpdate();
        verifyNoSend();
      },
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'whose send is parked is refused',
      setUp: () {
        answerUpdate();
        when(() => sender.deliver(any(), any()))
            .thenAnswer((_) async => const SyncParked('400'));
      },
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(edit(quantity: 3));
      },
      skip: 2,
      expect: () => [
        ready(
          row(),
          action: CollectionEntryAction.saved,
          sync: CollectionSync.refused,
        ),
      ],
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'whose send is not claimed is queued',
      setUp: () {
        answerUpdate();
        when(() => sender.deliver(any(), any()))
            .thenAnswer((_) async => const SyncNotClaimed());
      },
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(edit(quantity: 3));
      },
      skip: 2,
      expect: () => [
        ready(
          row(),
          action: CollectionEntryAction.saved,
          sync: CollectionSync.queued,
        ),
      ],
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'whose claim throws is queued, and the claim failure is logged',
      setUp: () {
        answerUpdate();
        when(() => sender.deliver(any(), any())).thenThrow(StateError('x'));
      },
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(edit(quantity: 3));
      },
      skip: 2,
      expect: () => [
        ready(
          row(),
          action: CollectionEntryAction.saved,
          sync: CollectionSync.queued,
        ),
      ],
      verify: (_) => verify(
        () => logger.error(
          any(),
          error: any(named: 'error'),
          stackTrace: any(named: 'stackTrace'),
        ),
      ).called(1),
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'whose write throws is saveFailed and sends nothing',
      setUp: () => when(callUpdate).thenThrow(StateError('disposed')),
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(edit(quantity: 3));
      },
      skip: 2,
      expect: () => [ready(row(), action: CollectionEntryAction.saveFailed)],
      verify: (_) => verifyNoSend(),
    );

    // The sheet's form is frozen when it opens, so a row that changed under
    // it (a hydrate bringing another device's edit) must not make the fields
    // nobody touched look changed, nor have them written back over it.
    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'is judged against the entry the sheet opened on, not the latest row',
      setUp: answerUpdate,
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        // Another device's change arrives while the sheet is open.
        await show(bloc, row(quantity: 5));
        bloc.add(edit(comment: 'better', base: row().entry));
      },
      verify: (_) => verify(
        () => repository.updateCollectionEntry(
          id: 'gc_1',
          comment: 'better',
        ),
      ).called(1),
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'needs no row: one with a base and no row yet still writes',
      setUp: answerUpdate,
      build: build,
      act: (bloc) => bloc.add(edit(quantity: 3)),
      expect: () => [
        const CollectionEntryState(action: CollectionEntryAction.saving),
        const CollectionEntryState(
          action: CollectionEntryAction.saved,
          sync: CollectionSync.synced,
        ),
      ],
      verify: (_) => verify(
        () => repository.updateCollectionEntry(id: 'gc_1', quantity: 3),
      ).called(1),
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'submitted twice while saving is sent once',
      setUp: () {
        final gate = Completer<void>();
        when(callUpdate).thenAnswer((_) async {
          await gate.future;
          return (
            entry: row().entry,
            syncQueueId: 'sq_1',
            operation: _updateOp,
          );
        });
        addTearDown(() => gate.isCompleted ? null : gate.complete());
        _gate = gate;
      },
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc
          ..add(edit(quantity: 3))
          ..add(edit(quantity: 4));
        await pumpEventQueue();
        _gate.complete();
      },
      skip: 1,
      expect: () => [
        ready(row(), action: CollectionEntryAction.saving),
        ready(
          row(),
          action: CollectionEntryAction.saved,
          sync: CollectionSync.synced,
        ),
      ],
      verify: (_) => verify(callUpdate).called(1),
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'while a remove is under way is ignored',
      setUp: () {
        _gate = Completer<void>();
        when(() => repository.removeFromCollection('gc_1'))
            .thenAnswer((_) async {
              await _gate.future;
              return (syncQueueId: 'sq_2', operation: _removeOp);
            });
      },
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(const CollectionEntryRemoveConfirmed());
        await pumpEventQueue();
        bloc.add(edit(quantity: 3));
        await pumpEventQueue();
        _gate.complete();
      },
      verify: (_) => verifyNoUpdate(),
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'after the removal is ignored',
      setUp: () => when(() => repository.removeFromCollection('gc_1'))
          .thenAnswer((_) async => (syncQueueId: 'sq_2', operation: _removeOp)),
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(const CollectionEntryRemoveConfirmed());
        await pumpEventQueue();
        bloc.add(edit(quantity: 3));
      },
      verify: (_) => verifyNoUpdate(),
    );
  });

  group('a remove', () {
    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'sends at once and ends removed',
      setUp: () => when(() => repository.removeFromCollection('gc_1'))
          .thenAnswer((_) async => (syncQueueId: 'sq_2', operation: _removeOp)),
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(const CollectionEntryRemoveConfirmed());
      },
      skip: 1,
      expect: () => [
        ready(row(), action: CollectionEntryAction.removing),
        ready(
          row(),
          action: CollectionEntryAction.removed,
          sync: CollectionSync.synced,
        ),
      ],
      verify: (_) => verify(() => sender.deliver('sq_2', _removeOp)).called(1),
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'that returns null ends removed with no send',
      setUp: () =>
          when(() => repository.removeFromCollection('gc_1'))
              .thenAnswer((_) async => null),
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(const CollectionEntryRemoveConfirmed());
      },
      skip: 2,
      expect: () => [ready(row(), action: CollectionEntryAction.removed)],
      verify: (_) => verifyNoSend(),
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'that throws is removeFailed',
      setUp: () =>
          when(() => repository.removeFromCollection('gc_1'))
              .thenThrow(StateError('disposed')),
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(const CollectionEntryRemoveConfirmed());
      },
      skip: 2,
      expect: () => [ready(row(), action: CollectionEntryAction.removeFailed)],
      verify: (_) => verifyNoSend(),
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'needs no item',
      setUp: () => when(() => repository.removeFromCollection('gc_1'))
          .thenAnswer((_) async => (syncQueueId: 'sq_2', operation: _removeOp)),
      build: build,
      act: (bloc) => bloc.add(const CollectionEntryRemoveConfirmed()),
      skip: 1,
      expect: () => [
        const CollectionEntryState(
          action: CollectionEntryAction.removed,
          sync: CollectionSync.synced,
        ),
      ],
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'while saving is ignored',
      setUp: () {
        _gate = Completer<void>();
        when(callUpdate).thenAnswer((_) async {
          await _gate.future;
          return (
            entry: row().entry,
            syncQueueId: 'sq_1',
            operation: _updateOp,
          );
        });
      },
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(edit(quantity: 3));
        await pumpEventQueue();
        bloc.add(const CollectionEntryRemoveConfirmed());
        await pumpEventQueue();
        _gate.complete();
      },
      verify: (_) => verifyNever(() => repository.removeFromCollection(any())),
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'again after removed is ignored',
      setUp: () => when(() => repository.removeFromCollection('gc_1'))
          .thenAnswer((_) async => (syncQueueId: 'sq_2', operation: _removeOp)),
      build: build,
      act: (bloc) async {
        bloc.add(const CollectionEntryRemoveConfirmed());
        await pumpEventQueue();
        bloc.add(const CollectionEntryRemoveConfirmed());
      },
      verify: (_) =>
          verify(() => repository.removeFromCollection('gc_1')).called(1),
    );
  });

  group("the watch's null during the bloc's own removal", () {
    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'leaves view ready while removing',
      setUp: () {
        _gate = Completer<void>();
        when(() => repository.removeFromCollection('gc_1'))
            .thenAnswer((_) async {
              await _gate.future;
              return (syncQueueId: 'sq_2', operation: _removeOp);
            });
      },
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(const CollectionEntryRemoveConfirmed());
        await pumpEventQueue();
        await show(bloc, null);
        _gate.complete();
      },
      skip: 2,
      expect: () => [
        ready(
          row(),
          action: CollectionEntryAction.removed,
          sync: CollectionSync.synced,
        ),
      ],
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'after removed does not flash gone',
      setUp: () => when(() => repository.removeFromCollection('gc_1'))
          .thenAnswer((_) async => (syncQueueId: 'sq_2', operation: _removeOp)),
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(const CollectionEntryRemoveConfirmed());
        await pumpEventQueue();
        await show(bloc, null);
      },
      skip: 1,
      expect: () => [
        ready(row(), action: CollectionEntryAction.removing),
        ready(
          row(),
          action: CollectionEntryAction.removed,
          sync: CollectionSync.synced,
        ),
      ],
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'after removeFailed is gone',
      setUp: () =>
          when(() => repository.removeFromCollection('gc_1'))
              .thenThrow(StateError('disposed')),
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(const CollectionEntryRemoveConfirmed());
        await pumpEventQueue();
        await show(bloc, null);
      },
      skip: 3,
      expect: () => [
        CollectionEntryState(
          view: CollectionEntryView.gone,
          item: row(),
          action: CollectionEntryAction.removeFailed,
        ),
      ],
    );
  });

  group('clearing the action', () {
    for (final failed in [
      CollectionEntryAction.saveFailed,
      CollectionEntryAction.removeFailed,
    ]) {
      blocTest<CollectionEntryBloc, CollectionEntryState>(
        '$failed goes idle',
        setUp: () {
          when(callUpdate).thenThrow(StateError('x'));
          when(() => repository.removeFromCollection('gc_1'))
              .thenThrow(StateError('x'));
        },
        build: build,
        act: (bloc) async {
          await show(bloc, row());
          bloc.add(
            failed == CollectionEntryAction.saveFailed
                ? edit(quantity: 3)
                : const CollectionEntryRemoveConfirmed(),
          );
          await pumpEventQueue();
          bloc.add(const CollectionEntryActionCleared());
        },
        skip: 3,
        expect: () => [ready(row())],
      );
    }

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'saved goes idle, keeping view and item',
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(edit());
        await pumpEventQueue();
        bloc.add(const CollectionEntryActionCleared());
      },
      skip: 2,
      expect: () => [ready(row())],
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'does nothing while idle',
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(const CollectionEntryActionCleared());
      },
      expect: () => [ready(row())],
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'never clears saving',
      setUp: () {
        _gate = Completer<void>();
        when(callUpdate).thenAnswer((_) async {
          await _gate.future;
          return (
            entry: row().entry,
            syncQueueId: 'sq_1',
            operation: _updateOp,
          );
        });
      },
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(edit(quantity: 3));
        await pumpEventQueue();
        bloc.add(const CollectionEntryActionCleared());
        await pumpEventQueue();
        _gate.complete();
      },
      skip: 1,
      expect: () => [
        ready(row(), action: CollectionEntryAction.saving),
        ready(
          row(),
          action: CollectionEntryAction.saved,
          sync: CollectionSync.synced,
        ),
      ],
    );
  });

  blocTest<CollectionEntryBloc, CollectionEntryState>(
    'a remove begun while loading, then a null, never emits ready without '
    'an item',
    setUp: () {
      _gate = Completer<void>();
      when(() => repository.removeFromCollection('gc_1')).thenAnswer((_) async {
        await _gate.future;
        return (syncQueueId: 'sq_2', operation: _removeOp);
      });
    },
    build: build,
    act: (bloc) async {
      bloc.add(const CollectionEntryRemoveConfirmed());
      await pumpEventQueue();
      await show(bloc, null);
      _gate.complete();
    },
    expect: () => [
      const CollectionEntryState(action: CollectionEntryAction.removing),
      const CollectionEntryState(
        action: CollectionEntryAction.removed,
        sync: CollectionSync.synced,
      ),
    ],
  );

  blocTest<CollectionEntryBloc, CollectionEntryState>(
    'a watch that closes before its first row is error, logged',
    build: build,
    act: (bloc) async {
      await watch.close();
      await pumpEventQueue();
    },
    expect: () => [const CollectionEntryState(view: CollectionEntryView.error)],
    verify: (_) => verify(
      () => logger.warn(
        any(),
        error: any(named: 'error'),
        stackTrace: any(named: 'stackTrace'),
      ),
    ).called(1),
  );

  blocTest<CollectionEntryBloc, CollectionEntryState>(
    'a watch that closes after a row changes nothing',
    build: build,
    act: (bloc) async {
      await show(bloc, row());
      await watch.close();
      await pumpEventQueue();
    },
    expect: () => [ready(row())],
  );

  blocTest<CollectionEntryBloc, CollectionEntryState>(
    'an edit after the entry was removed elsewhere is saveFailed, still gone',
    setUp: () => when(callUpdate).thenThrow(StateError('removed')),
    build: build,
    act: (bloc) async {
      await show(bloc, row());
      await show(bloc, null);
      bloc.add(edit(quantity: 3));
    },
    skip: 2,
    expect: () => [
      CollectionEntryState(
        view: CollectionEntryView.gone,
        item: row(),
      ).withAction(CollectionEntryAction.saving),
      CollectionEntryState(
        view: CollectionEntryView.gone,
        item: row(),
      ).withAction(CollectionEntryAction.saveFailed),
    ],
    verify: (_) => verifyNoSend(),
  );

  group('a retry', () {
    /// Each watch the bloc opened, in the order it opened them. The first is
    /// [watch], whose tear-down close waits for a listener.
    late List<StreamController<GameCollectionListItem?>> watches;

    void answerEachWatch() {
      watches = [];
      when(() => repository.watchCollectionListItem('gc_1')).thenAnswer((_) {
        final opened = watches.isEmpty
            ? watch
            : StreamController<GameCollectionListItem?>();
        if (watches.isNotEmpty) addTearDown(opened.close);
        watches.add(opened);
        return opened.stream;
      });
    }

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'after an error watches again, loading until the new watch answers',
      setUp: answerEachWatch,
      build: build,
      act: (bloc) async {
        watches.single.addError(StateError('the read failed'));
        await pumpEventQueue();
        bloc.add(const CollectionEntryRetried());
        await pumpEventQueue();
        watches.last.add(row());
        await pumpEventQueue();
      },
      expect: () => [
        const CollectionEntryState(view: CollectionEntryView.error),
        const CollectionEntryState(),
        ready(row()),
      ],
      verify: (_) {
        verify(() => repository.watchCollectionListItem('gc_1')).called(2);
        // The failed watch is let go.
        expect(watches.first.hasListener, isFalse);
      },
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'whose watch also closes before answering is error again',
      setUp: answerEachWatch,
      build: build,
      act: (bloc) async {
        await watches.single.close();
        await pumpEventQueue();
        bloc.add(const CollectionEntryRetried());
        await pumpEventQueue();
        await watches.last.close();
        await pumpEventQueue();
      },
      expect: () => [
        const CollectionEntryState(view: CollectionEntryView.error),
        const CollectionEntryState(),
        const CollectionEntryState(view: CollectionEntryView.error),
      ],
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'does nothing unless the view is error',
      setUp: answerEachWatch,
      build: build,
      act: (bloc) async {
        watches.single.add(row());
        await pumpEventQueue();
        bloc.add(const CollectionEntryRetried());
      },
      expect: () => [ready(row())],
      verify: (_) =>
          verify(() => repository.watchCollectionListItem('gc_1')).called(1),
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'twice at once watches once more, not twice',
      setUp: answerEachWatch,
      build: build,
      act: (bloc) async {
        watches.single.addError(StateError('the read failed'));
        await pumpEventQueue();
        bloc
          ..add(const CollectionEntryRetried())
          ..add(const CollectionEntryRetried());
        await pumpEventQueue();
      },
      verify: (_) =>
          verify(() => repository.watchCollectionListItem('gc_1')).called(2),
    );
  });

  group('an entry the cache has never held', () {
    late StreamController<Hydration> hydration;

    setUp(() {
      hydration = StreamController<Hydration>();
      addTearDown(hydration.close);
    });

    CollectionEntryBloc buildHydrating() => CollectionEntryBloc(
      repository: repository,
      sender: sender,
      entryId: 'gc_1',
      hydration: hydration.stream,
      logger: logger,
    );

    Future<void> say(Hydration reading) async {
      hydration.add(reading);
      await pumpEventQueue();
    }

    const running = Hydration(state: HydrationState.running);
    const refreshed = Hydration(
      state: HydrationState.refreshed,
      everRefreshed: true,
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'is loading while a pass runs, and gone once it lands without it',
      build: buildHydrating,
      act: (bloc) async {
        await say(running);
        await show(bloc, null);
        expect(bloc.state, const CollectionEntryState());
        await say(refreshed);
      },
      expect: () => [
        const CollectionEntryState(view: CollectionEntryView.gone),
      ],
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'is ready when the pass writes it',
      build: buildHydrating,
      act: (bloc) async {
        await say(running);
        await show(bloc, null);
        await show(bloc, row());
        await say(refreshed);
      },
      expect: () => [ready(row())],
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'waits for the status to speak, and an idle one settles it',
      build: buildHydrating,
      act: (bloc) async {
        await show(bloc, null);
        expect(bloc.state, const CollectionEntryState());
        await say(const Hydration());
      },
      expect: () => [
        const CollectionEntryState(view: CollectionEntryView.gone),
      ],
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'is gone at once when a pass has landed rows before, even while another '
      'runs',
      build: buildHydrating,
      act: (bloc) async {
        await say(
          const Hydration(state: HydrationState.running, everRefreshed: true),
        );
        await show(bloc, null);
      },
      expect: () => [
        const CollectionEntryState(view: CollectionEntryView.gone),
      ],
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'is gone when the status stream closes without speaking',
      build: buildHydrating,
      act: (bloc) async {
        await show(bloc, null);
        await hydration.close();
        await pumpEventQueue();
      },
      expect: () => [
        const CollectionEntryState(view: CollectionEntryView.gone),
      ],
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'once read, a null is gone at once, even while a pass runs',
      build: buildHydrating,
      act: (bloc) async {
        await say(running);
        await show(bloc, row());
        await show(bloc, null);
      },
      expect: () => [
        ready(row()),
        CollectionEntryState(view: CollectionEntryView.gone, item: row()),
      ],
    );

    test('closing cancels the status subscription', () async {
      final bloc = buildHydrating();
      await pumpEventQueue();
      expect(hydration.hasListener, isTrue);

      await bloc.close();

      expect(hydration.hasListener, isFalse);
    });
  });

  blocTest<CollectionEntryBloc, CollectionEntryState>(
    'an untouched comment with surrounding space is not sent',
    setUp: answerUpdate,
    build: build,
    act: (bloc) async {
      final spaced = GameCollectionListItem(
        entry: row().entry.copyWith(comment: 'Great game '),
        gameId: row().gameId,
        title: row().title,
        subtitle: row().subtitle,
        platformName: row().platformName,
        thumbnail: row().thumbnail,
      );
      await show(bloc, spaced);
      bloc.add(
        edit(base: spaced.entry, comment: 'Great game ', favorite: true),
      );
      await pumpEventQueue();
    },
    verify: (_) => verify(
      () => repository.updateCollectionEntry(
        id: 'gc_1',
        favorite: true,
      ),
    ).called(1),
  );

  blocTest<CollectionEntryBloc, CollectionEntryState>(
    'a removal that throws once the entry is gone ends removed, with no send',
    setUp: () =>
        when(() => repository.removeFromCollection('gc_1'))
            .thenThrow(StateError('not found')),
    build: build,
    act: (bloc) async {
      await show(bloc, row());
      await show(bloc, null);
      bloc.add(const CollectionEntryRemoveConfirmed());
    },
    skip: 2,
    expect: () => [
      CollectionEntryState(
        view: CollectionEntryView.gone,
        item: row(),
        action: CollectionEntryAction.removing,
      ),
      CollectionEntryState(
        view: CollectionEntryView.gone,
        item: row(),
        action: CollectionEntryAction.removed,
      ),
    ],
    verify: (_) => verifyNoSend(),
  );

  blocTest<CollectionEntryBloc, CollectionEntryState>(
    'a removal that throws after the row went while it was under way ends '
    'removed, with no send',
    setUp: () {
      _gate = Completer<void>();
      when(() => repository.removeFromCollection('gc_1')).thenAnswer((_) async {
        await _gate.future;
        throw StateError('not found');
      });
    },
    build: build,
    act: (bloc) async {
      await show(bloc, row());
      bloc.add(const CollectionEntryRemoveConfirmed());
      await pumpEventQueue();
      // Purged by a sync while the removal waited: its null arrives first,
      // and the removal's own read then finds nothing.
      await show(bloc, null);
      _gate.complete();
      await pumpEventQueue();
      bloc.add(const CollectionEntryActionCleared());
    },
    skip: 2,
    expect: () => [
      ready(row(), action: CollectionEntryAction.removed),
      CollectionEntryState(view: CollectionEntryView.gone, item: row()),
    ],
    verify: (_) => verifyNoSend(),
  );

  group('clearing removed', () {
    void answerRemove() => when(() => repository.removeFromCollection('gc_1'))
        .thenAnswer((_) async => (syncQueueId: 'sq_2', operation: _removeOp));

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'whose row went is idle and gone, and a re-add is ready',
      setUp: answerRemove,
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(const CollectionEntryRemoveConfirmed());
        // The removal's own null, ignored while it is under way.
        await show(bloc, null);
        bloc.add(const CollectionEntryActionCleared());
        await pumpEventQueue();
        await show(bloc, row(quantity: 1));
      },
      skip: 3,
      expect: () => [
        CollectionEntryState(view: CollectionEntryView.gone, item: row()),
        ready(row(quantity: 1)),
      ],
    );

    blocTest<CollectionEntryBloc, CollectionEntryState>(
      'before its row went is idle, and the null after is gone',
      setUp: answerRemove,
      build: build,
      act: (bloc) async {
        await show(bloc, row());
        bloc.add(const CollectionEntryRemoveConfirmed());
        await pumpEventQueue();
        bloc.add(const CollectionEntryActionCleared());
        await pumpEventQueue();
        await show(bloc, null);
      },
      skip: 3,
      expect: () => [
        ready(row()),
        CollectionEntryState(view: CollectionEntryView.gone, item: row()),
      ],
    );
  });

  test('a retry in the same turn as close opens no watch', () async {
    final opened = <StreamController<GameCollectionListItem?>>[watch];
    when(() => repository.watchCollectionListItem('gc_1')).thenAnswer((_) {
      if (opened.length == 1 && !watch.hasListener) return watch.stream;
      final next = StreamController<GameCollectionListItem?>();
      addTearDown(next.close);
      opened.add(next);
      return next.stream;
    });
    final bloc = build();
    watch.addError(StateError('the read failed'));
    await pumpEventQueue();
    expect(bloc.state.view, CollectionEntryView.error);

    bloc.add(const CollectionEntryRetried());
    await bloc.close();

    expect(opened, hasLength(1));
    expect(watch.hasListener, isFalse);
  });

  test('closing cancels the watch', () async {
    final bloc = build();
    await bloc.close();

    expect(watch.hasListener, isFalse);
  });
}

/// Held by the tests that need a write to stay in flight.
late Completer<void> _gate;
