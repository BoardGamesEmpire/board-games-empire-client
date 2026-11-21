import 'dart:async';

import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../support/fake_event_remote.dart';

class _MockBgeLogger extends Mock implements BgeLogger {}

/// Requests that wait for the test to answer them, in the order they were
/// sent.
final class _Held<R, T> {
  final List<R> requests = [];
  final List<Completer<T>> _replies = [];

  Future<T> call(R request) {
    final reply = Completer<T>();
    requests.add(request);
    _replies.add(reply);
    return reply.future;
  }

  /// Answers the [index]th request with [value].
  void answer(int index, T value) => _replies[index].complete(value);

  /// Answers the [index]th request with [error].
  void fail(int index, Object error) => _replies[index].completeError(error);
}

const _gone = EventRemoteNotFoundException('gone', statusCode: 404);
const _forbidden = EventRemoteForbiddenException('hidden', statusCode: 403);
const _offline = EventRemoteTransientException('offline');

const _loading = EventLineupState(load: EventLineupLoad.loading);

/// The lineup game `l-[n]` of `Game [n]`.
LineupGame _game(int n) => LineupGame(
  id: 'l-$n',
  platformGameId: 'pg-$n',
  gameId: 'game-$n',
  title: 'Game $n',
  platformName: 'Tabletop',
  role: ScheduledGameRole.primary,
  sortOrder: n,
  suppliedById: 'g-$n',
  supplierAttendeeId: 'a-$n',
);

/// The lineup of an event, read online and never cached (#519).
void main() {
  late _MockBgeLogger logger;
  late List<LineupGame> one;
  late List<LineupGame> two;

  setUp(() {
    logger = _MockBgeLogger();
    one = [_game(1)];
    two = [_game(1), _game(2)];
  });

  FakeEventRemote serving(
    FutureOr<List<LineupGame>> Function(String eventId) lineup,
  ) => FakeEventRemote.detail(
    (_) => throw UnimplementedError('the lineup reads no event'),
    lineup: lineup,
  );

  EventLineupBloc build(
    FakeEventRemote remote, {
    Future<bool> Function()? confirmSession,
  }) => EventLineupBloc(
    remote: remote,
    confirmSession: confirmSession,
    logger: logger,
  );

  List<EventLineupState> record(EventLineupBloc bloc) {
    final states = <EventLineupState>[];
    final subscription = bloc.stream.listen(states.add);
    addTearDown(subscription.cancel);
    return states;
  }

  EventLineupState loaded(List<LineupGame> games) => EventLineupState(
    load: EventLineupLoad.loaded,
    games: games,
    answered: true,
  );

  void verifyWarnings(int count) => verify(
    () => logger.warn(
      any(),
      error: any(named: 'error'),
      stackTrace: any(named: 'stackTrace'),
    ),
  ).called(count);

  test('a read loads the lineup', () async {
    final remote = serving((_) => two);
    final bloc = build(remote);
    addTearDown(bloc.close);
    final states = record(bloc);

    bloc.add(const EventLineupRequested('e-1'));
    await pumpEventQueue();

    expect(remote.lineupRequests, ['e-1']);
    expect(states, [_loading, loaded(two)]);
    expect(knownLineup(bloc.state), two);
  });

  test('knownLineup is null until a read has answered', () {
    expect(knownLineup(null), isNull);
    expect(knownLineup(const EventLineupState()), isNull);
    expect(knownLineup(loaded(const [])), isEmpty);
  });

  test('a second request while reading reads once more after', () async {
    final reads = _Held<String, List<LineupGame>>();
    final remote = serving(reads.call);
    final bloc = build(remote);
    addTearDown(bloc.close);
    final states = record(bloc);

    bloc.add(const EventLineupRequested('e-1'));
    await pumpEventQueue();
    bloc
      ..add(const EventLineupRequested('e-2'))
      ..add(const EventLineupRequested('e-3'));
    await pumpEventQueue();

    // Never two at once.
    expect(remote.lineupRequests, ['e-1']);

    reads.answer(0, one);
    await pumpEventQueue();

    // One more, for the latest request's event.
    expect(remote.lineupRequests, ['e-1', 'e-3']);

    reads.answer(1, two);
    await pumpEventQueue();

    expect(remote.lineupRequests, hasLength(2));
    expect(states, [
      _loading,
      loaded(one),
      EventLineupState(
        load: EventLineupLoad.loading,
        games: one,
        answered: true,
      ),
      loaded(two),
    ]);
  });

  test('403 hides the lineup', () async {
    final bloc = build(serving((_) => throw _forbidden));
    addTearDown(bloc.close);
    final states = record(bloc);

    bloc.add(const EventLineupRequested('e-1'));
    await pumpEventQueue();

    expect(states, [
      _loading,
      const EventLineupState(load: EventLineupLoad.hidden),
    ]);
    expect(knownLineup(bloc.state), isNull);
  });

  test('404 is gone, and failed when the read started gone', () async {
    final bloc = build(serving((_) => throw _gone));
    addTearDown(bloc.close);
    final states = record(bloc);

    bloc.add(const EventLineupRequested('e-1'));
    await pumpEventQueue();
    // No loading between, so a refused viewer sees nothing change.
    bloc.add(const EventLineupRequested('e-1'));
    await pumpEventQueue();

    expect(states, [
      _loading,
      const EventLineupState(load: EventLineupLoad.gone),
      const EventLineupState(
        load: EventLineupLoad.failed,
        refreshFailed: true,
      ),
    ]);
  });

  test('a refusal clears the rows a read had answered', () async {
    var refuse = false;
    final bloc = build(serving((_) => refuse ? throw _forbidden : one));
    addTearDown(bloc.close);

    bloc.add(const EventLineupRequested('e-1'));
    await pumpEventQueue();
    expect(knownLineup(bloc.state), one);

    refuse = true;
    bloc.add(const EventLineupRequested('e-1'));
    await pumpEventQueue();

    expect(bloc.state, const EventLineupState(load: EventLineupLoad.hidden));
  });

  test('a failed re-read keeps the rows and stays answered', () async {
    var fail = false;
    final bloc = build(serving((_) => fail ? throw _offline : one));
    addTearDown(bloc.close);

    bloc.add(const EventLineupRequested('e-1'));
    await pumpEventQueue();
    fail = true;
    bloc.add(const EventLineupRequested('e-1'));
    await pumpEventQueue();

    expect(
      bloc.state,
      EventLineupState(
        load: EventLineupLoad.failed,
        games: one,
        answered: true,
        refreshFailed: true,
      ),
    );
    expect(knownLineup(bloc.state), one);
    verifyWarnings(1);
  });

  test('retry marks refreshing', () async {
    final reads = _Held<String, List<LineupGame>>();
    Completer<bool>? asked;
    final bloc = build(
      serving(reads.call),
      confirmSession: () => asked?.future ?? Future.value(true),
    );
    addTearDown(bloc.close);

    bloc.add(const EventLineupRequested('e-1'));
    await pumpEventQueue();
    reads.fail(0, _offline);
    await pumpEventQueue();
    expect(bloc.state.load, EventLineupLoad.failed);

    final session = asked = Completer();
    final states = record(bloc);
    bloc.add(const EventLineupRetryRequested('e-1'));
    await pumpEventQueue();

    // At once, before the session has answered.
    expect(states, [
      const EventLineupState(
        load: EventLineupLoad.failed,
        refreshFailed: true,
        refreshing: true,
      ),
    ]);

    session.complete(true);
    await pumpEventQueue();
    reads.answer(1, two);
    await pumpEventQueue();

    expect(states.sublist(1), [
      const EventLineupState(
        load: EventLineupLoad.loading,
        refreshFailed: true,
        refreshing: true,
      ),
      loaded(two),
    ]);
  });

  test('a retry while a read is out is under way until the read after it '
      'ends', () async {
    final reads = _Held<String, List<LineupGame>>();
    final bloc = build(serving(reads.call));
    addTearDown(bloc.close);
    final states = record(bloc);

    bloc.add(const EventLineupRequested('e-1'));
    await pumpEventQueue();
    bloc.add(const EventLineupRetryRequested('e-1'));
    await pumpEventQueue();
    reads.answer(0, one);
    await pumpEventQueue();

    // The read that was out went before the retry, so the retry's own read
    // follows it.
    expect(reads.requests, hasLength(2));

    reads.answer(1, two);
    await pumpEventQueue();

    expect(states, [
      _loading,
      const EventLineupState(load: EventLineupLoad.loading, refreshing: true),
      EventLineupState(
        load: EventLineupLoad.loaded,
        games: one,
        answered: true,
        refreshing: true,
      ),
      EventLineupState(
        load: EventLineupLoad.loading,
        games: one,
        answered: true,
        refreshing: true,
      ),
      loaded(two),
    ]);
  });

  test('a read after a retry is not narrated as refreshing', () async {
    final bloc = build(serving((_) => one));
    addTearDown(bloc.close);

    bloc.add(const EventLineupRetryRequested('e-1'));
    await pumpEventQueue();
    expect(bloc.state, loaded(one));

    final states = record(bloc);
    bloc.add(const EventLineupRequested('e-1'));
    await pumpEventQueue();

    expect(states, [
      EventLineupState(
        load: EventLineupLoad.loading,
        games: one,
        answered: true,
      ),
      loaded(one),
    ]);
  });

  test('a read that ends after close emits nothing', () async {
    final reads = _Held<String, List<LineupGame>>();
    final bloc = build(serving(reads.call));
    final states = record(bloc);
    final errors = <Object>[];
    final watching = bloc.stream.listen(null, onError: errors.add);
    addTearDown(watching.cancel);

    bloc.add(const EventLineupRequested('e-1'));
    await pumpEventQueue();
    final before = List.of(states);

    await bloc.close();
    reads.answer(0, one);
    await pumpEventQueue();

    expect(states, before);
    expect(errors, isEmpty);
  });

  test('a lost session ends the read without rows', () async {
    final reads = _Held<String, List<LineupGame>>();
    final answers = [true, false, false];
    var asked = 0;
    final bloc = build(
      serving(reads.call),
      confirmSession: () async => answers[asked++],
    );
    addTearDown(bloc.close);
    final states = record(bloc);

    bloc.add(const EventLineupRequested('e-1'));
    await pumpEventQueue();
    reads.answer(0, two);
    await pumpEventQueue();

    // The answer could be another user's, so it is dropped.
    expect(states, [
      _loading,
      const EventLineupState(
        load: EventLineupLoad.failed,
        refreshFailed: true,
      ),
    ]);
    expect(knownLineup(bloc.state), isNull);

    // And a session that is lost before the send sends nothing.
    bloc.add(const EventLineupRequested('e-1'));
    await pumpEventQueue();
    expect(reads.requests, hasLength(1));
    // A no, not a throw from the check.
    verifyNever(
      () => logger.warn(
        any(),
        error: any(named: 'error'),
        stackTrace: any(named: 'stackTrace'),
      ),
    );
  });

  group('writes', () {
    /// The pool row `g-[n]` of `Game [n]`, offered by `a-[n]`.
    OfferedGame pool(int n) => OfferedGame(
      id: 'g-$n',
      attendeeId: 'a-$n',
      collectionId: 'c-$n',
      platformGameId: 'pg-$n',
      gameId: 'game-$n',
      title: 'Game $n',
      subtitle: 'Sub $n',
      platformName: 'Tabletop',
    );

    FakeEventRemote writing({
      FutureOr<LineupGame> Function(DirectAddRequest request)? added,
      FutureOr<LineupGame> Function(LineupRemoveRequest request)? removed,
      FutureOr<List<LineupGame>> Function(String eventId)? lineup,
    }) => FakeEventRemote.detail(
      (_) => throw UnimplementedError('the lineup reads no event'),
      lineup: lineup ?? (_) => two,
      directAdded: added ?? (_) => _game(2),
      lineupRemoved: removed ?? (_) => _game(1),
    );

    EventLineupState seen(
      List<LineupGame> games, {
      LineupWriting? writing,
      EventLineupOutcome? outcome,
    }) => EventLineupState(
      load: EventLineupLoad.loaded,
      games: games,
      answered: true,
      writing: writing,
      outcome: outcome,
    );

    test('an add sends, re-reads and says done', () async {
      final remote = writing(lineup: (_) => two);
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(
        LineupGameAdded(
          'e-1',
          pool(2),
          occurrenceId: 'o-1',
          role: ScheduledGameRole.filler,
          notes: 'late',
          maxPlayTime: 30,
        ),
      );
      await pumpEventQueue();

      expect(remote.directAdds, [
        (
          eventId: 'e-1',
          platformGameId: 'pg-2',
          suppliedById: 'g-2',
          occurrenceId: 'o-1',
          role: ScheduledGameRole.filler,
          notes: 'late',
          maxPlayTime: 30,
        ),
      ]);
      expect(remote.lineupRequests, ['e-1']);
      expect(bloc.state.writing, isNull);
      expect(bloc.state.games, two);
      expect(
        bloc.state.outcome,
        const LineupAddOutcome(
          LineupAddResult.done,
          title: 'Game 2',
          subtitle: 'Sub 2',
        ),
      );

      bloc.add(const EventLineupOutcomeDismissed());
      await pumpEventQueue();
      expect(bloc.state.outcome, isNull);
    });

    test('an add shows itself writing, and clears the last outcome', () async {
      final held = _Held<DirectAddRequest, LineupGame>();
      final bloc = build(writing(added: held.call));
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(LineupGameAdded('e-1', pool(2)));
      await pumpEventQueue();

      expect(states.first.writing, (write: LineupWrite.add, id: 'g-2'));
      expect(states.first.busy, isTrue);

      held.answer(0, _game(2));
      await pumpEventQueue();
      expect(bloc.state.busy, isFalse);
    });

    test('an add refused, gone, supplier not going', () async {
      for (final (error, result) in <(Exception, LineupAddResult)>[
        (
          const EventWriteRefusedException('no', statusCode: 403),
          LineupAddResult.refused,
        ),
        (_gone, LineupAddResult.gone),
        (
          const EventWriteConflictException('away', statusCode: 409),
          LineupAddResult.supplierNotGoing,
        ),
        (_offline, LineupAddResult.failed),
        (
          const EventRemotePermanentException('bad', statusCode: 400),
          LineupAddResult.failed,
        ),
      ]) {
        final remote = writing(added: (_) => throw error);
        final bloc = build(remote);
        addTearDown(bloc.close);

        bloc.add(LineupGameAdded('e-1', pool(2)));
        await pumpEventQueue();

        expect(
          bloc.state.outcome,
          LineupAddOutcome(result, title: 'Game 2', subtitle: 'Sub 2'),
          reason: '$error',
        );
        // A sent write reads again, whatever it said.
        expect(remote.lineupRequests, ['e-1'], reason: '$error');
      }
    });

    test('a remove sends, re-reads and says done', () async {
      var lineup = two;
      final remote = writing(
        lineup: (_) => lineup,
        removed: (_) {
          lineup = one;
          return _game(2);
        },
      );
      final bloc = build(remote);
      addTearDown(bloc.close);
      bloc.add(const EventLineupRequested('e-1'));
      await pumpEventQueue();

      bloc.add(LineupGameRemoved('e-1', _game(2)));
      await pumpEventQueue();

      expect(remote.lineupRemovals, [(eventId: 'e-1', lineupGameId: 'l-2')]);
      expect(remote.lineupRequests, ['e-1', 'e-1']);
      expect(bloc.state.games, one);
      expect(
        bloc.state.outcome,
        const LineupRemoveOutcome(LineupRemoveResult.done, title: 'Game 2'),
      );
    });

    test('a remove of a game already gone says so and drops it', () async {
      final remote = writing(
        lineup: (_) => two,
        removed: (_) => throw _gone,
      );
      final bloc = build(remote);
      addTearDown(bloc.close);
      final states = record(bloc);
      bloc.add(const EventLineupRequested('e-1'));
      await pumpEventQueue();
      states.clear();

      bloc.add(LineupGameRemoved('e-1', _game(2)));
      await pumpEventQueue();

      // The row is dropped at once, with the outcome, ahead of the read.
      expect(
        states.firstWhere((each) => each.outcome != null),
        seen(
          [_game(1)],
          outcome: const LineupRemoveOutcome(
            LineupRemoveResult.alreadyGone,
            title: 'Game 2',
          ),
        ),
      );
      expect(remote.lineupRequests, ['e-1', 'e-1']);
    });

    test('a read out across a removal answers without the game', () async {
      final reads = _Held<String, List<LineupGame>>();
      final remote = writing(lineup: reads.call);
      final bloc = build(remote);
      addTearDown(bloc.close);
      bloc.add(const EventLineupRequested('e-1'));
      await pumpEventQueue();
      reads.answer(0, two);
      await pumpEventQueue();

      // A read goes out, then the removal ends while it is out.
      bloc.add(const EventLineupRequested('e-1'));
      await pumpEventQueue();
      bloc.add(LineupGameRemoved('e-1', _game(2)));
      await pumpEventQueue();
      expect(bloc.state.games, one);

      // Served before the delete, it still has the game.
      reads.answer(1, two);
      await pumpEventQueue();
      expect(bloc.state.games, one);

      // The read after the removal started after it, so it is taken as it
      // comes, even with the game back in it.
      expect(remote.lineupRequests, ['e-1', 'e-1', 'e-1']);
      reads.answer(2, two);
      await pumpEventQueue();
      expect(bloc.state.games, two);
    });

    test('a read that fails after a removal keeps the game out', () async {
      final reads = _Held<String, List<LineupGame>>();
      final remote = writing(lineup: reads.call);
      final bloc = build(remote);
      addTearDown(bloc.close);
      bloc.add(const EventLineupRequested('e-1'));
      await pumpEventQueue();
      reads.answer(0, two);
      await pumpEventQueue();

      bloc.add(const EventLineupRequested('e-1'));
      await pumpEventQueue();
      bloc.add(LineupGameRemoved('e-1', _game(2)));
      await pumpEventQueue();
      reads.answer(1, two);
      await pumpEventQueue();
      // The read after the removal fails, keeping what was shown.
      reads.fail(2, _offline);
      await pumpEventQueue();

      expect(bloc.state.games, one);
      expect(bloc.state.refreshFailed, isTrue);
    });

    test('a started lineup says started', () async {
      final remote = writing(
        removed: (_) => throw const EventWriteConflictException(
          'started',
          statusCode: 409,
          code: 'LINEUP_STARTED',
        ),
      );
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(LineupGameRemoved('e-1', _game(1)));
      await pumpEventQueue();

      expect(
        bloc.state.outcome,
        const LineupRemoveOutcome(LineupRemoveResult.started, title: 'Game 1'),
      );
      // The lineup is read again, and the game is still in it.
      expect(remote.lineupRequests, ['e-1']);
    });

    test('a remove refused or failed says so', () async {
      for (final (error, result) in <(Exception, LineupRemoveResult)>[
        (
          const EventWriteRefusedException('no', statusCode: 403),
          LineupRemoveResult.refused,
        ),
        (_offline, LineupRemoveResult.failed),
        (
          const EventWriteConflictException('odd', statusCode: 409),
          LineupRemoveResult.failed,
        ),
      ]) {
        final bloc = build(writing(removed: (_) => throw error));
        addTearDown(bloc.close);

        bloc.add(LineupGameRemoved('e-1', _game(1)));
        await pumpEventQueue();

        expect(
          bloc.state.outcome,
          LineupRemoveOutcome(result, title: 'Game 1'),
          reason: '$error',
        );
      }
    });

    test('a second write while one is out is ignored', () async {
      final held = _Held<LineupRemoveRequest, LineupGame>();
      final remote = writing(removed: held.call);
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(LineupGameRemoved('e-1', _game(1)));
      await pumpEventQueue();
      bloc
        ..add(LineupGameRemoved('e-1', _game(2)))
        ..add(LineupGameAdded('e-1', pool(3)))
        ..add(const LineupWriteDropped(LineupWrite.add, title: 'Game 3'));
      await pumpEventQueue();

      expect(held.requests, hasLength(1));
      expect(remote.directAdds, isEmpty);
      expect(bloc.state.outcome, isNull);
      expect(bloc.state.writing, (write: LineupWrite.remove, id: 'l-1'));

      held.answer(0, _game(1));
      await pumpEventQueue();
      expect(bloc.state.busy, isFalse);
    });

    test('a dropped write says so and sends nothing', () async {
      final remote = writing();
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(
        const LineupWriteDropped(
          LineupWrite.remove,
          title: 'Game 1',
          subtitle: 'Sub',
        ),
      );
      await pumpEventQueue();

      expect(
        bloc.state.outcome,
        const LineupRemoveOutcome(
          LineupRemoveResult.dropped,
          title: 'Game 1',
          subtitle: 'Sub',
        ),
      );
      expect(remote.lineupRemovals, isEmpty);
      expect(remote.lineupRequests, isEmpty);
    });

    test('the same drop twice is two outcomes, cleared between', () async {
      // A screen reader hears an outcome as it lands, so a second drop must
      // land as a state of its own.
      final bloc = build(writing());
      addTearDown(bloc.close);
      final states = <EventLineupState>[];
      final listening = bloc.stream.listen(states.add);
      addTearDown(listening.cancel);
      const drop = LineupWriteDropped(LineupWrite.add, title: 'Game 1');
      const dropped = LineupAddOutcome(
        LineupAddResult.dropped,
        title: 'Game 1',
      );

      bloc.add(drop);
      await pumpEventQueue();
      bloc.add(drop);
      await pumpEventQueue();

      expect(
        [for (final state in states) state.outcome],
        [
          dropped,
          null,
          dropped,
        ],
      );
    });

    test('a session that is lost sends nothing and says failed', () async {
      final remote = writing();
      final bloc = build(remote, confirmSession: () async => false);
      addTearDown(bloc.close);

      bloc.add(LineupGameAdded('e-1', pool(2)));
      await pumpEventQueue();

      expect(remote.directAdds, isEmpty);
      expect(
        bloc.state.outcome,
        const LineupAddOutcome(
          LineupAddResult.failed,
          title: 'Game 2',
          subtitle: 'Sub 2',
        ),
      );
    });
  });
}
