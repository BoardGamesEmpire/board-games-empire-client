import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
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

const _refused = EventWriteRefusedException('no', statusCode: 403);
const _gone = EventRemoteNotFoundException('gone', statusCode: 404);
const _forbidden = EventRemoteForbiddenException('hidden', statusCode: 403);
const _offline = EventRemoteTransientException('offline');
const _tooMany = EventRemoteTransientException('slow down', statusCode: 429);
const _supplierNotGoing = EventWriteConflictException(
  'not going',
  statusCode: 409,
);
const _notSupplied = EventWriteConflictException(
  'not supplied',
  statusCode: 400,
);
const _closed = EventWriteConflictException('closed', statusCode: 400);

const _idle = EventNominationsState();
const _loading = EventNominationsState(load: EventNominationsLoad.loading);

/// The nomination `n-[n]` of `Game [n]`, supplied from the pool row `g-[n]`.
EventNomination _nomination(
  int n, {
  NominationStatus status = NominationStatus.open,
}) => EventNomination(
  id: 'n-$n',
  eventId: 'e-1',
  platformGameId: 'pg-$n',
  gameId: 'game-$n',
  title: 'Game $n',
  platformName: 'Tabletop',
  status: status,
  nominatedById: 'a-1',
  suppliedFromId: 'g-$n',
  createdAt: DateTime.utc(2026, 11, n),
);

/// [nomination] with the viewer's vote [voteType] on it.
EventNomination _votedOn(EventNomination nomination, VoteType voteType) =>
    nomination.copyWith(
      votes: [
        EventNominationVote(
          id: 'v-${nomination.id}',
          attendeeId: 'a-1',
          voteType: voteType,
          eligible: true,
        ),
      ],
    );

/// The pool row `g-[n]` of `Game [n]`.
OfferedGame _game(int n) => OfferedGame(
  id: 'g-$n',
  attendeeId: 'a-2',
  collectionId: 'c-$n',
  platformGameId: 'pg-$n',
  gameId: 'game-$n',
  title: 'Game $n',
  platformName: 'Tabletop',
);

/// A nominate on the event `e-1` of the pool row `g-[n]`.
GameNominated _nominate(int n, {String? occurrenceId}) =>
    GameNominated('e-1', _game(n), occurrenceId: occurrenceId);

/// A vote of [voteType] on the event `e-1`'s [nomination].
NominationVoteCast _vote(
  EventNomination nomination, [
  VoteType voteType = VoteType.forGame,
]) => NominationVoteCast('e-1', nomination, voteType);

/// A withdrawal of the event `e-1`'s [nomination].
NominationWithdrawn _withdraw(EventNomination nomination) =>
    NominationWithdrawn('e-1', nomination);

/// The nominations on an event's Games tab (#517). Every nomination is read,
/// and never cached. Nominate, vote and withdraw go straight to the server,
/// one at a time, and their answers change the rows they are about.
void main() {
  late _MockBgeLogger logger;

  /// What the bloc called, in order.
  late List<String> calls;

  setUp(() {
    logger = _MockBgeLogger();
    calls = [];
  });

  /// A server whose reads and writes answer as given, each recorded in
  /// [calls]. A list read answers no nominations and a vote is recorded,
  /// unless a test says otherwise; any other request a test doesn't answer
  /// throws.
  FakeEventRemote serving({
    FutureOr<List<EventNomination>> Function(NominationsRequest request)?
    nominations,
    FutureOr<EventNomination> Function(NominationRequest request)? nomination,
    FutureOr<EventNomination> Function(NominateRequest request)? nominated,
    FutureOr<void> Function(CastVoteRequest request)? voteCast,
    FutureOr<EventNomination> Function(WithdrawRequest request)? withdrawn,
  }) => FakeEventRemote.detail(
    (_) => throw UnimplementedError('the nominations read no event'),
    nominations: (request) {
      calls.add('read');
      return nominations == null
          ? const <EventNomination>[]
          : nominations(request);
    },
    nomination: (request) {
      calls.add('readOne');
      if (nomination == null) throw UnimplementedError('no single read');
      return nomination(request);
    },
    nominated: (request) {
      calls.add('nominate');
      if (nominated == null) throw UnimplementedError('no nominate');
      return nominated(request);
    },
    voteCast: (request) {
      calls.add('vote');
      if (voteCast != null) return voteCast(request);
    },
    withdrawn: (request) {
      calls.add('withdraw');
      if (withdrawn == null) throw UnimplementedError('no withdrawal');
      return withdrawn(request);
    },
  );

  EventNominationsBloc build(
    FakeEventRemote remote, {
    Future<bool> Function()? confirmSession,
  }) => EventNominationsBloc(
    remote: remote,
    confirmSession: confirmSession,
    logger: logger,
  );

  /// A guard that answers each of [answers] in turn, then the last again.
  Future<bool> Function() answering(List<bool> answers) {
    var asked = 0;
    return () async {
      calls.add('session');
      return answers[asked < answers.length ? asked++ : asked - 1];
    };
  }

  /// Every state [bloc] emits from now on.
  List<EventNominationsState> record(EventNominationsBloc bloc) {
    final states = <EventNominationsState>[];
    final subscription = bloc.stream.listen(states.add);
    addTearDown(subscription.cancel);
    return states;
  }

  /// A bloc on [remote] that has read the event `e-1`'s nominations once,
  /// with [calls] cleared after.
  Future<EventNominationsBloc> readFirst(
    FakeEventRemote remote, {
    Future<bool> Function()? confirmSession,
  }) async {
    final bloc = build(remote, confirmSession: confirmSession);
    addTearDown(bloc.close);
    bloc.add(const EventNominationsRequested('e-1'));
    await pumpEventQueue();
    expect(bloc.state.load, EventNominationsLoad.loaded);
    calls.clear();
    return bloc;
  }

  EventNominationsState loaded(
    List<EventNomination> nominations, {
    NominationWriting? writing,
    EventNominationsOutcome? outcome,
    bool settling = false,
  }) => EventNominationsState(
    load: EventNominationsLoad.loaded,
    nominations: nominations,
    writing: writing,
    outcome: outcome,
    settling: settling,
  );

  /// A read under way, showing [nominations].
  EventNominationsState loading(
    List<EventNomination> nominations, {
    EventNominationsOutcome? outcome,
    bool settling = false,
  }) => EventNominationsState(
    load: EventNominationsLoad.loading,
    nominations: nominations,
    outcome: outcome,
    settling: settling,
  );

  /// A read that ended failed, keeping [nominations].
  EventNominationsState failed({
    List<EventNomination> nominations = const [],
    EventNominationsOutcome? outcome,
    bool settling = false,
  }) => EventNominationsState(
    load: EventNominationsLoad.failed,
    nominations: nominations,
    outcome: outcome,
    refreshFailed: true,
    settling: settling,
  );

  void verifyWarnings(int count) => verify(
    () => logger.warn(
      any(),
      error: any(named: 'error'),
      stackTrace: any(named: 'stackTrace'),
    ),
  ).called(count);

  void verifyNoWarnings() => verifyNever(
    () => logger.warn(
      any(),
      error: any(named: 'error'),
      stackTrace: any(named: 'stackTrace'),
    ),
  );

  final n1 = _nomination(1);
  final n2 = _nomination(2);
  final one = [n1];
  final two = [n1, n2];

  test('starts idle, with nothing out', () {
    final bloc = build(serving());
    addTearDown(bloc.close);

    expect(bloc.state, _idle);
    expect(bloc.state.busy, isFalse);
  });

  group('reads', () {
    test('reads every nomination once requested', () async {
      final remote = serving(nominations: (_) => two);
      final bloc = build(remote);
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(const EventNominationsRequested('e-1'));
      await pumpEventQueue();

      expect(remote.nominationReads, ['e-1']);
      expect(states, [_loading, loaded(two)]);
    });

    test(
      'a read while one is out queues one more for the latest event id',
      () async {
        final reads = _Held<NominationsRequest, List<EventNomination>>();
        final remote = serving(nominations: reads.call);
        final bloc = build(remote);
        addTearDown(bloc.close);
        final states = record(bloc);

        bloc.add(const EventNominationsRequested('e-1'));
        await pumpEventQueue();
        bloc
          ..add(const EventNominationsRequested('e-2'))
          ..add(const EventNominationsRequested('e-3'));
        await pumpEventQueue();

        // Never two at once.
        expect(remote.nominationReads, ['e-1']);

        reads.answer(0, one);
        await pumpEventQueue();

        // One more, for the latest request's event.
        expect(remote.nominationReads, ['e-1', 'e-3']);

        reads.answer(1, two);
        await pumpEventQueue();

        expect(remote.nominationReads, hasLength(2));
        expect(states, [
          _loading,
          loaded(one),
          EventNominationsState(
            load: EventNominationsLoad.loading,
            nominations: one,
          ),
          loaded(two),
        ]);
      },
    );

    for (final (name, error, load) in [
      (
        'a 403 read is hidden and clears the nominations',
        _forbidden,
        EventNominationsLoad.hidden,
      ),
      (
        'a 404 read is gone and clears the nominations',
        _gone,
        EventNominationsLoad.gone,
      ),
    ]) {
      blocTest<EventNominationsBloc, EventNominationsState>(
        name,
        build: () => build(serving(nominations: (_) => throw error)),
        seed: () => loaded(one),
        act: (bloc) => bloc.add(const EventNominationsRequested('e-1')),
        expect: () => [
          EventNominationsState(
            load: EventNominationsLoad.loading,
            nominations: one,
          ),
          EventNominationsState(load: load),
        ],
        verify: (_) => verifyNoWarnings(),
      );
    }

    blocTest<EventNominationsBloc, EventNominationsState>(
      'a failed read keeps the nominations read before',
      build: () => build(serving(nominations: (_) => throw _offline)),
      seed: () => loaded(one),
      act: (bloc) => bloc.add(const EventNominationsRequested('e-1')),
      expect: () => [
        EventNominationsState(
          load: EventNominationsLoad.loading,
          nominations: one,
        ),
        failed(nominations: one),
      ],
      verify: (_) => verifyWarnings(1),
    );

    for (final load in [
      EventNominationsLoad.hidden,
      EventNominationsLoad.gone,
    ]) {
      blocTest<EventNominationsBloc, EventNominationsState>(
        'a read after a ${load.name} keeps that load until it answers',
        build: () => build(serving(nominations: (_) => one)),
        seed: () => EventNominationsState(load: load),
        act: (bloc) => bloc.add(const EventNominationsRequested('e-1')),
        // No loading between, so a refused viewer sees nothing change.
        expect: () => [loaded(one)],
      );
    }

    // The event's own read settles a gone. Nominations still not found once
    // that has read the event fine is a failure the user can retry.
    blocTest<EventNominationsBloc, EventNominationsState>(
      'a 404 read that started gone ends failed, with no nominations',
      build: () => build(serving(nominations: (_) => throw _gone)),
      seed: () => const EventNominationsState(load: EventNominationsLoad.gone),
      act: (bloc) => bloc.add(const EventNominationsRequested('e-1')),
      expect: () => [failed()],
    );

    test('a retry is refreshing from the press', () async {
      final reads = _Held<NominationsRequest, List<EventNomination>>();
      Completer<bool>? asked;
      final remote = serving(nominations: reads.call);
      final bloc = build(
        remote,
        confirmSession: () => asked?.future ?? Future.value(true),
      );
      addTearDown(bloc.close);

      bloc.add(const EventNominationsRequested('e-1'));
      await pumpEventQueue();
      reads.answer(0, one);
      await pumpEventQueue();
      bloc.add(const EventNominationsRequested('e-1'));
      await pumpEventQueue();
      reads.fail(1, _offline);
      await pumpEventQueue();
      expect(bloc.state, failed(nominations: one));

      final session = asked = Completer();
      final states = record(bloc);

      bloc.add(const EventNominationsRetryRequested('e-1'));
      await pumpEventQueue();

      // At once, before the session has answered: the retry is under way.
      expect(states, [
        EventNominationsState(
          load: EventNominationsLoad.failed,
          nominations: one,
          refreshFailed: true,
          refreshing: true,
        ),
      ]);
      expect(remote.nominationReads, hasLength(2));

      session.complete(true);
      await pumpEventQueue();
      reads.answer(2, two);
      await pumpEventQueue();

      expect(states.sublist(1), [
        EventNominationsState(
          load: EventNominationsLoad.loading,
          nominations: one,
          refreshFailed: true,
          refreshing: true,
        ),
        loaded(two),
      ]);
    });
  });

  group('the session', () {
    test('is asked before each send and each read, and before each answer is '
        'used', () async {
      final remote = serving(
        nominations: (_) => one,
        nominated: (_) => n2,
        nomination: (_) => _votedOn(n2, VoteType.forGame),
        withdrawn: (_) => n2.copyWith(status: NominationStatus.withdrawn),
      );
      final bloc = await readFirst(remote, confirmSession: answering([true]));

      // Each write is followed by a read of the list, asked about as any
      // read is.
      bloc.add(_nominate(2));
      await pumpEventQueue();
      expect(calls, [
        'session',
        'nominate',
        'session',
        'session',
        'read',
        'session',
      ]);

      calls.clear();
      bloc.add(_vote(n2));
      await pumpEventQueue();
      expect(calls, [
        'session',
        'vote',
        'session',
        'readOne',
        'session',
        'session',
        'read',
        'session',
      ]);

      calls.clear();
      bloc.add(_withdraw(n2));
      await pumpEventQueue();
      expect(calls, [
        'session',
        'withdraw',
        'session',
        'session',
        'read',
        'session',
      ]);
    });

    test('a session that says no sends nothing and fails the write', () async {
      final bloc = build(serving(), confirmSession: answering([false]));
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(_nominate(2));
      await pumpEventQueue();
      bloc.add(_vote(n2));
      await pumpEventQueue();
      bloc.add(_withdraw(n2));
      await pumpEventQueue();

      // Nothing sent, nothing read after, and a nominate that never went
      // out leaves nothing to settle.
      expect(calls, ['session', 'session', 'session']);
      expect(bloc.state.settling, isFalse);
      expect(states, const [
        EventNominationsState(
          writing: (write: NominationWrite.nominate, id: 'g-2'),
        ),
        EventNominationsState(
          outcome: NominateOutcome(NominateResult.failed, title: 'Game 2'),
        ),
        EventNominationsState(
          writing: (write: NominationWrite.vote, id: 'n-2'),
        ),
        EventNominationsState(
          outcome: VoteOutcome(VoteResult.failed, title: 'Game 2'),
        ),
        EventNominationsState(
          writing: (write: NominationWrite.withdraw, id: 'n-2'),
        ),
        EventNominationsState(
          outcome: WithdrawOutcome(WithdrawResult.failed, title: 'Game 2'),
        ),
      ]);
      verifyNoWarnings();
    });

    test('a session that throws is a no, and logged', () async {
      final bloc = build(
        serving(),
        confirmSession: () async => throw StateError('no answer'),
      );
      addTearDown(bloc.close);

      bloc.add(_nominate(2));
      await pumpEventQueue();

      expect(calls, isEmpty);
      expect(
        bloc.state,
        const EventNominationsState(
          outcome: NominateOutcome(NominateResult.failed, title: 'Game 2'),
        ),
      );
      verifyWarnings(1);
    });

    for (final (name, read)
        in <(String, List<EventNomination> Function(NominationsRequest))>[
          ('nominations', (_) => two),
          ('a refusal', (_) => throw _forbidden),
          ('a gone', (_) => throw _gone),
        ]) {
      blocTest<EventNominationsBloc, EventNominationsState>(
        "$name answered after the session moved is another user's, and the "
        'read is failed, keeping the nominations',
        build: () => build(
          serving(nominations: read),
          confirmSession: answering([true, false]),
        ),
        seed: () => loaded(one),
        act: (bloc) => bloc.add(const EventNominationsRequested('e-1')),
        skip: 1,
        expect: () => [failed(nominations: one)],
        verify: (_) => expect(calls, ['session', 'read', 'session']),
      );
    }

    blocTest<EventNominationsBloc, EventNominationsState>(
      'a nominate answered after the session moved is failed, its answer '
      'unused, and settling, and the read after it fails too',
      build: () => build(
        serving(nominated: (_) => n2),
        confirmSession: answering([true, false]),
      ),
      seed: () => loaded(one),
      act: (bloc) => bloc.add(_nominate(2)),
      skip: 1,
      expect: () {
        const failedOutcome = NominateOutcome(
          NominateResult.failed,
          title: 'Game 2',
        );
        return [
          loaded(one, outcome: failedOutcome, settling: true),
          failed(nominations: one, outcome: failedOutcome, settling: true),
        ];
      },
      verify: (_) =>
          expect(calls, ['session', 'nominate', 'session', 'session']),
    );

    blocTest<EventNominationsBloc, EventNominationsState>(
      "a vote's 404 answered after the session moved is failed, and the row "
      'kept, and the read after it fails too',
      build: () => build(
        serving(voteCast: (_) => throw _gone),
        confirmSession: answering([true, false]),
      ),
      seed: () => loaded(two),
      act: (bloc) => bloc.add(_vote(n2)),
      skip: 1,
      expect: () => [
        loaded(
          two,
          outcome: const VoteOutcome(VoteResult.failed, title: 'Game 2'),
        ),
        failed(
          nominations: two,
          outcome: const VoteOutcome(VoteResult.failed, title: 'Game 2'),
        ),
      ],
      verify: (_) => expect(calls, ['session', 'vote', 'session', 'session']),
    );

    blocTest<EventNominationsBloc, EventNominationsState>(
      "a withdrawal's 404 answered after the session moved is failed, and the "
      'row kept, and the read after it fails too',
      build: () => build(
        serving(withdrawn: (_) => throw _gone),
        confirmSession: answering([true, false]),
      ),
      seed: () => loaded(two),
      act: (bloc) => bloc.add(_withdraw(n2)),
      skip: 1,
      expect: () => [
        loaded(
          two,
          outcome: const WithdrawOutcome(
            WithdrawResult.failed,
            title: 'Game 2',
          ),
        ),
        failed(
          nominations: two,
          outcome: const WithdrawOutcome(
            WithdrawResult.failed,
            title: 'Game 2',
          ),
        ),
      ],
      verify: (_) =>
          expect(calls, ['session', 'withdraw', 'session', 'session']),
    );

    blocTest<EventNominationsBloc, EventNominationsState>(
      'a withdrawal answered after the session moved is failed, its answer '
      'unused, and the read after it fails too',
      build: () => build(
        serving(
          withdrawn: (_) => n2.copyWith(status: NominationStatus.withdrawn),
        ),
        confirmSession: answering([true, false]),
      ),
      seed: () => loaded(two),
      act: (bloc) => bloc.add(_withdraw(n2)),
      skip: 1,
      expect: () => [
        loaded(
          two,
          outcome: const WithdrawOutcome(
            WithdrawResult.failed,
            title: 'Game 2',
          ),
        ),
        failed(
          nominations: two,
          outcome: const WithdrawOutcome(
            WithdrawResult.failed,
            title: 'Game 2',
          ),
        ),
      ],
      verify: (_) =>
          expect(calls, ['session', 'withdraw', 'session', 'session']),
    );

    test('a vote whose single read meets a moved session is done, and the '
        'list read after it is failed', () async {
      final remote = serving(
        nominations: (_) => two,
        nomination: (_) => _votedOn(n2, VoteType.forGame),
      );
      final bloc = await readFirst(
        remote,
        confirmSession: answering([true, true, true, true, false]),
      );

      bloc.add(_vote(n2));
      await pumpEventQueue();

      expect(calls, [
        'session',
        'vote',
        'session',
        'readOne',
        'session',
        'session',
      ]);
      expect(
        bloc.state,
        failed(
          nominations: two,
          outcome: const VoteOutcome(
            VoteResult.done,
            title: 'Game 2',
            voteType: VoteType.forGame,
          ),
        ),
      );
    });
  });

  group('nominate', () {
    test('nominate inserts the answer, says voting is open, and reads the '
        'list after it', () async {
      final sends = _Held<NominateRequest, EventNomination>();
      var listed = one;
      final remote = serving(
        nominations: (_) => listed,
        nominated: sends.call,
      );
      final bloc = await readFirst(remote);
      final states = record(bloc);

      bloc.add(_nominate(2, occurrenceId: 'o-1'));
      await pumpEventQueue();

      expect(bloc.state.busy, isTrue);
      expect(remote.nominates, [
        (
          eventId: 'e-1',
          platformGameId: 'pg-2',
          suppliedFromId: 'g-2',
          occurrenceId: 'o-1',
        ),
      ]);

      // The server now holds it, and someone else's vote on n1 too.
      final votedN1 = _votedOn(n1, VoteType.against);
      listed = [n2, votedN1];
      sends.answer(0, n2);
      await pumpEventQueue();

      const open = NominateOutcome(NominateResult.open, title: 'Game 2');
      expect(states, [
        loaded(one, writing: (write: NominationWrite.nominate, id: 'g-2')),
        // The answer goes in at once, in the state its outcome lands in.
        loaded([n2, n1], outcome: open),
        loading([n2, n1], outcome: open),
        // The read after it brings what else changed.
        loaded([n2, votedN1], outcome: open),
      ]);
      expect(calls, ['nominate', 'read']);
    });

    blocTest<EventNominationsBloc, EventNominationsState>(
      'nominate under Direct says it went into the lineup',
      build: () => build(
        serving(
          nominated: (_) => n2.copyWith(status: NominationStatus.passed),
          nominations: (_) => [
            n2.copyWith(status: NominationStatus.passed),
            n1,
          ],
        ),
      ),
      seed: () => loaded(one),
      act: (bloc) => bloc.add(_nominate(2)),
      skip: 1,
      expect: () {
        final rows = [n2.copyWith(status: NominationStatus.passed), n1];
        const inLineup = NominateOutcome(
          NominateResult.inLineup,
          title: 'Game 2',
        );
        return [
          loaded(rows, outcome: inLineup),
          loading(rows, outcome: inLineup),
          loaded(rows, outcome: inLineup),
        ];
      },
      verify: (_) => expect(calls, ['nominate', 'read']),
    );

    for (final (status, result) in [
      (NominationStatus.awaitingApproval, NominateResult.awaitingApproval),
      (NominationStatus.approved, NominateResult.inLineup),
      (NominationStatus.paused, NominateResult.settled),
      (NominationStatus.failed, NominateResult.settled),
      (NominationStatus.unknown, NominateResult.settled),
    ]) {
      blocTest<EventNominationsBloc, EventNominationsState>(
        'an answer ${status.name} says ${result.name}',
        build: () => build(
          serving(nominated: (_) => _nomination(2, status: status)),
        ),
        act: (bloc) => bloc.add(_nominate(2)),
        skip: 1,
        // The outcome, then the read after it, which keeps it.
        expect: () => List.filled(
          3,
          isA<EventNominationsState>().having(
            (state) => state.outcome,
            'outcome',
            NominateOutcome(result, title: 'Game 2'),
          ),
        ),
      );
    }

    blocTest<EventNominationsBloc, EventNominationsState>(
      'the answer goes to the head, in place of a row with its id',
      build: () => build(
        serving(
          nominated: (_) =>
              n2.copyWith(status: NominationStatus.awaitingApproval),
          // A server that still lists it as it was, so the read's answer
          // shows it came after the answer.
          nominations: (_) => two,
        ),
      ),
      seed: () => loaded(two),
      act: (bloc) => bloc.add(_nominate(2)),
      skip: 1,
      expect: () {
        final rows = [
          n2.copyWith(status: NominationStatus.awaitingApproval),
          n1,
        ];
        const awaiting = NominateOutcome(
          NominateResult.awaitingApproval,
          title: 'Game 2',
        );
        return [
          loaded(rows, outcome: awaiting),
          loading(rows, outcome: awaiting),
          loaded(two, outcome: awaiting),
        ];
      },
    );

    blocTest<EventNominationsBloc, EventNominationsState>(
      "nominate 409 says the supplier isn't going, and reads the list after it",
      build: () => build(
        serving(
          nominated: (_) => throw _supplierNotGoing,
          nominations: (_) => one,
        ),
      ),
      seed: () => loaded(one),
      act: (bloc) => bloc.add(_nominate(2)),
      expect: () {
        const notGoing = NominateOutcome(
          NominateResult.supplierNotGoing,
          title: 'Game 2',
        );
        return [
          loaded(one, writing: (write: NominationWrite.nominate, id: 'g-2')),
          loaded(one, outcome: notGoing),
          loading(one, outcome: notGoing),
          loaded(one, outcome: notGoing),
        ];
      },
      verify: (_) {
        expect(calls, ['nominate', 'read']);
        verifyNoWarnings();
      },
    );

    for (final (name, error, result, warnings) in [
      (
        'a 400, the row not supplying the game, is notSupplied',
        _notSupplied,
        NominateResult.notSupplied,
        0,
      ),
      ('a 403 is refused', _refused, NominateResult.refused, 0),
    ]) {
      blocTest<EventNominationsBloc, EventNominationsState>(
        '$name, and reads the list after it',
        build: () => build(
          serving(nominated: (_) => throw error, nominations: (_) => two),
        ),
        seed: () => loaded(one),
        act: (bloc) => bloc.add(_nominate(2)),
        skip: 1,
        expect: () {
          final outcome = NominateOutcome(result, title: 'Game 2');
          return [
            loaded(one, outcome: outcome),
            loading(one, outcome: outcome),
            loaded(two, outcome: outcome),
          ];
        },
        verify: (_) {
          expect(calls, ['nominate', 'read']);
          if (warnings == 0) {
            verifyNoWarnings();
          } else {
            verifyWarnings(warnings);
          }
        },
      );
    }

    // The server may have saved it, and takes the same row twice for one
    // choice (backend#1214), so the rows can't say what a pool row supplies
    // until a read after it loads, which shows a nomination that landed.
    for (final (name, error) in [
      ('a 429 is failed', _tooMany),
      ('anything else is failed', _offline),
    ]) {
      blocTest<EventNominationsBloc, EventNominationsState>(
        '$name and settling, and the read after it settles it',
        build: () => build(
          serving(nominated: (_) => throw error, nominations: (_) => two),
        ),
        seed: () => loaded(one),
        act: (bloc) => bloc.add(_nominate(2)),
        skip: 1,
        expect: () {
          const failedOutcome = NominateOutcome(
            NominateResult.failed,
            title: 'Game 2',
          );
          return [
            loaded(one, outcome: failedOutcome, settling: true),
            loading(one, outcome: failedOutcome, settling: true),
            loaded(two, outcome: failedOutcome),
          ];
        },
        verify: (_) {
          expect(calls, ['nominate', 'read']);
          verifyWarnings(1);
        },
      );
    }

    blocTest<EventNominationsBloc, EventNominationsState>(
      'a 404 is gone, and reads the nominations',
      build: () => build(
        serving(nominated: (_) => throw _gone, nominations: (_) => two),
      ),
      seed: () => loaded(one),
      act: (bloc) => bloc.add(_nominate(2)),
      skip: 1,
      expect: () {
        const gone = NominateOutcome(NominateResult.gone, title: 'Game 2');
        return [
          loaded(one, outcome: gone),
          EventNominationsState(
            load: EventNominationsLoad.loading,
            nominations: one,
            outcome: gone,
          ),
          loaded(two, outcome: gone),
        ];
      },
      verify: (_) => expect(calls, ['nominate', 'read']),
    );
  });

  group('a vote', () {
    test('a vote reads the one nomination again and replaces it, then the '
        'list', () async {
      final reads = _Held<NominationRequest, EventNomination>();
      var listed = two;
      final remote = serving(
        nominations: (_) => listed,
        nomination: reads.call,
      );
      final bloc = await readFirst(remote);
      final states = record(bloc);

      bloc.add(
        NominationVoteCast('e-1', n2, VoteType.forGame, comment: 'Yes please'),
      );
      await pumpEventQueue();

      expect(remote.votes, [
        (
          eventId: 'e-1',
          nominationId: 'n-2',
          voteType: VoteType.forGame,
          comment: 'Yes please',
        ),
      ]);
      expect(reads.requests, [(eventId: 'e-1', nominationId: 'n-2')]);
      // Still out until the read answers, so the outcome never lands beside
      // the row as it was before the vote.
      expect(states, [
        loaded(two, writing: (write: NominationWrite.vote, id: 'n-2')),
      ]);

      final voted = _votedOn(n2, VoteType.forGame);
      listed = [n1, voted];
      reads.answer(0, voted);
      await pumpEventQueue();

      const done = VoteOutcome(
        VoteResult.done,
        title: 'Game 2',
        voteType: VoteType.forGame,
      );
      expect(states.sublist(1), [
        loaded([n1, voted], outcome: done),
        loading([n1, voted], outcome: done),
        loaded([n1, voted], outcome: done),
      ]);
      expect(calls, ['vote', 'readOne', 'read']);
    });

    test(
      'a vote answered 400 reads the nomination again and says voting '
      'closed, then reads the list',
      () async {
        final closedRow = n2.copyWith(status: NominationStatus.failed);
        var listed = two;
        final bloc = await readFirst(
          serving(
            nominations: (_) => listed,
            voteCast: (_) => throw _closed,
            nomination: (_) => closedRow,
          ),
        );
        listed = [n1, closedRow];
        final states = record(bloc);

        bloc.add(_vote(n2));
        await pumpEventQueue();

        const closed = VoteOutcome(VoteResult.closed, title: 'Game 2');
        expect(states, [
          loaded(two, writing: (write: NominationWrite.vote, id: 'n-2')),
          loaded([n1, closedRow], outcome: closed),
          loading([n1, closedRow], outcome: closed),
          loaded([n1, closedRow], outcome: closed),
        ]);
        expect(calls, ['vote', 'readOne', 'read']);
        verifyNoWarnings();
      },
    );

    for (final (name, castError, outcome) in [
      (
        'a vote whose single read fails reads the whole list',
        null,
        const VoteOutcome(
          VoteResult.done,
          title: 'Game 2',
          voteType: VoteType.against,
        ),
      ),
      (
        'a vote answered 400 whose single read fails reads the whole list',
        _closed,
        const VoteOutcome(VoteResult.closed, title: 'Game 2'),
      ),
    ]) {
      test(name, () async {
        final voted = _votedOn(n2, VoteType.against);
        var listed = two;
        final bloc = await readFirst(
          serving(
            nominations: (_) => listed,
            voteCast: (_) {
              if (castError != null) throw castError;
            },
            nomination: (_) => throw _offline,
          ),
        );
        listed = [n1, voted];
        final states = record(bloc);

        bloc.add(_vote(n2, VoteType.against));
        await pumpEventQueue();

        expect(states, [
          loaded(two, writing: (write: NominationWrite.vote, id: 'n-2')),
          // At once, as the single read fails.
          loaded(two, outcome: outcome),
          EventNominationsState(
            load: EventNominationsLoad.loading,
            nominations: two,
            outcome: outcome,
          ),
          loaded([n1, voted], outcome: outcome),
        ]);
        expect(calls, ['vote', 'readOne', 'read']);
      });
    }

    for (final (name, error, result) in [
      ('a 403 is refused', _refused, VoteResult.refused),
      ('a 429 is failed', _tooMany, VoteResult.failed),
      ('anything else is failed', _offline, VoteResult.failed),
    ]) {
      blocTest<EventNominationsBloc, EventNominationsState>(
        '$name, and reads the list after it',
        build: () => build(
          serving(voteCast: (_) => throw error, nominations: (_) => two),
        ),
        seed: () => loaded(two),
        act: (bloc) => bloc.add(_vote(n2)),
        skip: 1,
        expect: () {
          final outcome = VoteOutcome(result, title: 'Game 2');
          return [
            loaded(two, outcome: outcome),
            loading(two, outcome: outcome),
            loaded(two, outcome: outcome),
          ];
        },
        verify: (_) => expect(calls, ['vote', 'read']),
      );
    }

    blocTest<EventNominationsBloc, EventNominationsState>(
      'a 404 is gone, drops the row, and reads the list after it',
      build: () => build(
        serving(voteCast: (_) => throw _gone, nominations: (_) => one),
      ),
      seed: () => loaded(two),
      act: (bloc) => bloc.add(_vote(n2)),
      skip: 1,
      expect: () {
        const gone = VoteOutcome(VoteResult.gone, title: 'Game 2');
        return [
          loaded(one, outcome: gone),
          loading(one, outcome: gone),
          loaded(one, outcome: gone),
        ];
      },
      verify: (_) => expect(calls, ['vote', 'read']),
    );
  });

  group('withdraw', () {
    test('withdraw replaces the row with the answer, and reads the list '
        'after it', () async {
      final withdrawn = n2.copyWith(status: NominationStatus.withdrawn);
      var listed = two;
      final remote = serving(
        nominations: (_) => listed,
        withdrawn: (_) => withdrawn,
      );
      final bloc = await readFirst(remote);
      listed = [n1, withdrawn];
      final states = record(bloc);

      bloc.add(_withdraw(n2));
      await pumpEventQueue();

      expect(remote.withdrawals, [(eventId: 'e-1', nominationId: 'n-2')]);
      const done = WithdrawOutcome(WithdrawResult.done, title: 'Game 2');
      expect(states, [
        loaded(two, writing: (write: NominationWrite.withdraw, id: 'n-2')),
        loaded([n1, withdrawn], outcome: done),
        loading([n1, withdrawn], outcome: done),
        loaded([n1, withdrawn], outcome: done),
      ]);
      expect(calls, ['withdraw', 'read']);
    });

    test('a 400 is notWithdrawable, and reads the nomination again, then the '
        'list', () async {
      final reads = _Held<NominationRequest, EventNomination>();
      final passed = n2.copyWith(status: NominationStatus.passed);
      var listed = two;
      final bloc = await readFirst(
        serving(
          nominations: (_) => listed,
          withdrawn: (_) => throw _closed,
          nomination: reads.call,
        ),
      );
      final states = record(bloc);

      bloc.add(_withdraw(n2));
      await pumpEventQueue();

      // Still out while the row is read again.
      expect(bloc.state.writing, (write: NominationWrite.withdraw, id: 'n-2'));

      listed = [n1, passed];
      reads.answer(0, passed);
      await pumpEventQueue();

      const notWithdrawable = WithdrawOutcome(
        WithdrawResult.notWithdrawable,
        title: 'Game 2',
      );
      expect(states, [
        loaded(two, writing: (write: NominationWrite.withdraw, id: 'n-2')),
        loaded([n1, passed], outcome: notWithdrawable),
        loading([n1, passed], outcome: notWithdrawable),
        loaded([n1, passed], outcome: notWithdrawable),
      ]);
      expect(calls, ['withdraw', 'readOne', 'read']);
    });

    test('a 400 whose single read fails reads the whole list', () async {
      final bloc = await readFirst(
        serving(
          nominations: (_) => two,
          withdrawn: (_) => throw _closed,
          nomination: (_) => throw _gone,
        ),
      );

      bloc.add(_withdraw(n2));
      await pumpEventQueue();

      expect(calls, ['withdraw', 'readOne', 'read']);
      expect(
        bloc.state,
        loaded(
          two,
          outcome: const WithdrawOutcome(
            WithdrawResult.notWithdrawable,
            title: 'Game 2',
          ),
        ),
      );
    });

    for (final (name, error, result) in [
      ('a 403 is refused', _refused, WithdrawResult.refused),
      ('anything else is failed', _offline, WithdrawResult.failed),
    ]) {
      blocTest<EventNominationsBloc, EventNominationsState>(
        '$name, and reads the list after it',
        build: () => build(
          serving(withdrawn: (_) => throw error, nominations: (_) => two),
        ),
        seed: () => loaded(two),
        act: (bloc) => bloc.add(_withdraw(n2)),
        skip: 1,
        expect: () {
          final outcome = WithdrawOutcome(result, title: 'Game 2');
          return [
            loaded(two, outcome: outcome),
            loading(two, outcome: outcome),
            loaded(two, outcome: outcome),
          ];
        },
        verify: (_) => expect(calls, ['withdraw', 'read']),
      );
    }

    blocTest<EventNominationsBloc, EventNominationsState>(
      'a 404 is gone, drops the row, and reads the list after it',
      build: () => build(
        serving(withdrawn: (_) => throw _gone, nominations: (_) => one),
      ),
      seed: () => loaded(two),
      act: (bloc) => bloc.add(_withdraw(n2)),
      skip: 1,
      expect: () {
        const gone = WithdrawOutcome(WithdrawResult.gone, title: 'Game 2');
        return [
          loaded(one, outcome: gone),
          loading(one, outcome: gone),
          loaded(one, outcome: gone),
        ];
      },
      verify: (_) => expect(calls, ['withdraw', 'read']),
    );
  });

  group('one write at a time', () {
    test('a write while one is out is ignored', () async {
      final sends = _Held<NominateRequest, EventNomination>();
      final bloc = await readFirst(
        serving(nominations: (_) => two, nominated: sends.call),
      );

      bloc.add(_nominate(3));
      await pumpEventQueue();
      final states = record(bloc);

      bloc
        ..add(_nominate(4))
        ..add(_vote(n2))
        ..add(_withdraw(n2))
        ..add(
          const NominationWriteDropped(NominationWrite.vote, title: 'Game 2'),
        );
      await pumpEventQueue();

      expect(calls, ['nominate']);
      expect(states, isEmpty);
      expect(bloc.state.writing, (write: NominationWrite.nominate, id: 'g-3'));
    });

    test("a vote's single read holds the write out", () async {
      final reads = _Held<NominationRequest, EventNomination>();
      final bloc = await readFirst(
        serving(nominations: (_) => two, nomination: reads.call),
      );

      bloc.add(_vote(n2));
      await pumpEventQueue();
      bloc.add(_withdraw(n2));
      await pumpEventQueue();

      expect(calls, ['vote', 'readOne']);
      expect(bloc.state.busy, isTrue);
      expect(bloc.state.outcome, isNull);
    });

    test('a read goes ahead while a write is out', () async {
      final sends = _Held<NominateRequest, EventNomination>();
      final bloc = await readFirst(
        serving(nominations: (_) => two, nominated: sends.call),
      );

      bloc.add(_nominate(3));
      await pumpEventQueue();
      bloc.add(const EventNominationsRequested('e-1'));
      await pumpEventQueue();

      expect(calls, ['nominate', 'read']);
      expect(
        bloc.state,
        loaded(two, writing: (write: NominationWrite.nominate, id: 'g-3')),
      );
    });
  });

  group("a read and a write's answer", () {
    /// A bloc whose nominations have read [first], with reads held by
    /// [reads] from the second on.
    Future<EventNominationsBloc> holding(
      List<EventNomination> first, {
      required _Held<NominationsRequest, List<EventNomination>> reads,
      FutureOr<EventNomination> Function(NominateRequest request)? nominated,
      FutureOr<void> Function(CastVoteRequest request)? voteCast,
      FutureOr<EventNomination> Function(NominationRequest request)? nomination,
    }) async {
      final bloc = build(
        serving(
          nominations: reads.call,
          nominated: nominated,
          voteCast: voteCast,
          nomination: nomination,
        ),
      );
      addTearDown(bloc.close);
      bloc.add(const EventNominationsRequested('e-1'));
      await pumpEventQueue();
      reads.answer(0, first);
      await pumpEventQueue();
      expect(bloc.state, loaded(first));
      return bloc;
    }

    test("a read out as a nominate ends keeps the nominate's answer over its "
        "own, and the nominate's own read after it does not", () async {
      final reads = _Held<NominationsRequest, List<EventNomination>>();
      final bloc = await holding(one, reads: reads, nominated: (_) => n2);

      // A read goes out, then the nominate, which ends before the read
      // answers.
      bloc.add(const EventNominationsRequested('e-1'));
      await pumpEventQueue();
      bloc.add(_nominate(2));
      await pumpEventQueue();
      expect(bloc.state.nominations, [n2, n1]);

      // That read went out before the nominate ended, so its answer can
      // lack it.
      reads.answer(1, one);
      await pumpEventQueue();
      const open = NominateOutcome(NominateResult.open, title: 'Game 2');
      // The nominate's own read went out as that one ended.
      expect(reads.requests, hasLength(3));
      expect(bloc.state, loading([n2, n1], outcome: open));

      // It went out after the nominate ended, so it is the server's word.
      reads.answer(2, one);
      await pumpEventQueue();
      expect(bloc.state, loaded(one, outcome: open));
      expect(reads.requests, hasLength(3));
    });

    test(
      "a read out as a vote ends keeps the vote's row over its own",
      () async {
        final reads = _Held<NominationsRequest, List<EventNomination>>();
        final voted = _votedOn(n2, VoteType.interested);
        final bloc = await holding(
          two,
          reads: reads,
          nomination: (_) => voted,
        );

        bloc.add(const EventNominationsRequested('e-1'));
        await pumpEventQueue();
        bloc.add(_vote(n2, VoteType.interested));
        await pumpEventQueue();
        expect(bloc.state.nominations, [n1, voted]);

        reads.answer(1, two);
        await pumpEventQueue();
        expect(bloc.state.nominations, [n1, voted]);
        // The vote's own read of the list, which went out after it.
        expect(reads.requests, hasLength(3));
        reads.answer(2, [n1, voted]);
        await pumpEventQueue();
        expect(bloc.state.nominations, [n1, voted]);
        expect(bloc.state.load, EventNominationsLoad.loaded);
      },
    );

    test(
      'a read out as a vote ends gone leaves the row out of its answer',
      () async {
        final reads = _Held<NominationsRequest, List<EventNomination>>();
        final bloc = await holding(
          two,
          reads: reads,
          voteCast: (_) => throw _gone,
        );

        bloc.add(const EventNominationsRequested('e-1'));
        await pumpEventQueue();
        bloc.add(_vote(n2));
        await pumpEventQueue();
        expect(bloc.state.nominations, one);

        reads.answer(1, two);
        await pumpEventQueue();
        expect(bloc.state.nominations, one);
      },
    );

    test("a read that answers while a vote is out takes the vote's row as it "
        'ends', () async {
      final reads = _Held<NominationsRequest, List<EventNomination>>();
      final rereads = _Held<NominationRequest, EventNomination>();
      final voted = _votedOn(n2, VoteType.forGame);
      final n3 = _nomination(3);
      final bloc = await holding(
        two,
        reads: reads,
        nomination: rereads.call,
      );

      bloc.add(_vote(n2));
      await pumpEventQueue();
      bloc.add(const EventNominationsRequested('e-1'));
      await pumpEventQueue();
      reads.answer(1, [n3, ...two]);
      await pumpEventQueue();
      expect(bloc.state.nominations, [n3, ...two]);

      rereads.answer(0, voted);
      await pumpEventQueue();
      expect(bloc.state.nominations, [n3, n1, voted]);
    });

    // Nominate is offered from a pool row, whatever the nominations' load,
    // so a viewer they are hidden from can still nominate.
    test('a nominate that ends while the nominations are hidden shows no '
        'row, and a read out then takes it', () async {
      final reads = _Held<NominationsRequest, List<EventNomination>>();
      final bloc = build(
        serving(nominations: reads.call, nominated: (_) => n2),
      );
      addTearDown(bloc.close);
      bloc.add(const EventNominationsRequested('e-1'));
      await pumpEventQueue();
      reads.fail(0, _forbidden);
      await pumpEventQueue();
      expect(bloc.state.load, EventNominationsLoad.hidden);

      bloc.add(const EventNominationsRequested('e-1'));
      await pumpEventQueue();
      bloc.add(_nominate(2));
      await pumpEventQueue();
      expect(
        bloc.state,
        const EventNominationsState(
          load: EventNominationsLoad.hidden,
          outcome: NominateOutcome(NominateResult.open, title: 'Game 2'),
        ),
      );

      reads.answer(1, one);
      await pumpEventQueue();
      expect(bloc.state.nominations, [n2, n1]);
    });
  });

  // A nominate whose answer was lost may have been saved, and the server
  // takes the same row twice for one choice (backend#1214), so the rows say
  // nothing of what a pool row supplies until a read that started after it
  // loads.
  group('settling', () {
    const lost = NominateOutcome(NominateResult.failed, title: 'Game 2');

    test('a failed read after a lost nominate keeps it settling until a '
        'retry loads', () async {
      var failing = true;
      final remote = serving(
        nominated: (_) => throw _offline,
        nominations: (_) {
          if (failing) throw _offline;
          return two;
        },
      );
      final bloc = build(remote);
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(_nominate(2));
      await pumpEventQueue();

      expect(calls, ['nominate', 'read']);
      expect(bloc.state, failed(outcome: lost, settling: true));

      failing = false;
      bloc.add(const EventNominationsRetryRequested('e-1'));
      await pumpEventQueue();

      expect(bloc.state, loaded(two, outcome: lost));
      expect(states.where((state) => state.settling), isNotEmpty);
      expect(calls, ['nominate', 'read', 'read']);
    });

    blocTest<EventNominationsBloc, EventNominationsState>(
      'a nominate while settling is ignored, and sends nothing',
      build: () => build(serving(nominated: (_) => n2)),
      seed: () => failed(nominations: one, outcome: lost, settling: true),
      act: (bloc) => bloc.add(_nominate(2)),
      expect: () => <EventNominationsState>[],
      verify: (_) => expect(calls, isEmpty),
    );

    test('a vote while settling still goes', () async {
      final bloc = build(
        serving(nominations: (_) => two, nomination: (_) => n2),
      );
      addTearDown(bloc.close);
      bloc
        ..emit(failed(nominations: two, outcome: lost, settling: true))
        ..add(_vote(n2));
      await pumpEventQueue();

      expect(calls, ['vote', 'readOne', 'read']);
      // Its read after started while settling, so it settles it.
      expect(bloc.state.settling, isFalse);
    });

    test('a read already out as a nominate is lost does not settle it; the '
        'read after the nominate does', () async {
      final reads = _Held<NominationsRequest, List<EventNomination>>();
      final bloc = build(
        serving(nominations: reads.call, nominated: (_) => throw _offline),
      );
      addTearDown(bloc.close);
      bloc.add(const EventNominationsRequested('e-1'));
      await pumpEventQueue();
      reads.answer(0, one);
      await pumpEventQueue();

      // A read goes out, then the nominate, whose answer is lost before
      // the read answers.
      bloc.add(const EventNominationsRequested('e-1'));
      await pumpEventQueue();
      bloc.add(_nominate(2));
      await pumpEventQueue();
      expect(bloc.state.settling, isTrue);

      // That read went out before the nominate ended, so its answer can
      // lack it.
      reads.answer(1, one);
      await pumpEventQueue();
      expect(bloc.state.settling, isTrue);
      expect(reads.requests, hasLength(3));

      reads.answer(2, two);
      await pumpEventQueue();
      expect(bloc.state, loaded(two, outcome: lost));
    });

    test('a hidden read after a lost nominate leaves it settling', () async {
      final bloc = build(
        serving(
          nominated: (_) => throw _offline,
          nominations: (_) => throw _forbidden,
        ),
      );
      addTearDown(bloc.close);

      bloc.add(_nominate(2));
      await pumpEventQueue();

      expect(bloc.state.load, EventNominationsLoad.hidden);
      expect(bloc.state.settling, isTrue);
    });
  });

  group('a dropped write', () {
    for (final (write, outcome) in <(NominationWrite, EventNominationsOutcome)>[
      (
        NominationWrite.nominate,
        const NominateOutcome(NominateResult.dropped, title: 'Game 2'),
      ),
      (
        NominationWrite.vote,
        const VoteOutcome(VoteResult.dropped, title: 'Game 2'),
      ),
      (
        NominationWrite.withdraw,
        const WithdrawOutcome(WithdrawResult.dropped, title: 'Game 2'),
      ),
    ]) {
      blocTest<EventNominationsBloc, EventNominationsState>(
        'a dropped ${write.name} sets its outcome and sends nothing',
        build: () => build(serving()),
        act: (bloc) => bloc.add(NominationWriteDropped(write, title: 'Game 2')),
        expect: () => [EventNominationsState(outcome: outcome)],
        verify: (_) => expect(calls, isEmpty),
      );
    }

    blocTest<EventNominationsBloc, EventNominationsState>(
      'the same drop twice is two outcomes, cleared between',
      build: () => build(serving()),
      act: (bloc) => bloc
        ..add(const NominationWriteDropped(NominationWrite.vote, title: 'A'))
        ..add(const NominationWriteDropped(NominationWrite.vote, title: 'A')),
      expect: () => const [
        EventNominationsState(
          outcome: VoteOutcome(VoteResult.dropped, title: 'A'),
        ),
        EventNominationsState(),
        EventNominationsState(
          outcome: VoteOutcome(VoteResult.dropped, title: 'A'),
        ),
      ],
      verify: (_) => expect(calls, isEmpty),
    );
  });

  group('the outcome', () {
    blocTest<EventNominationsBloc, EventNominationsState>(
      'a new write clears the last outcome as it starts',
      build: () => build(
        serving(nominated: (_) => throw _refused, nominations: (_) => one),
      ),
      seed: () => loaded(
        one,
        outcome: const VoteOutcome(VoteResult.refused, title: 'Game 1'),
      ),
      act: (bloc) => bloc.add(_nominate(2)),
      expect: () {
        const refused = NominateOutcome(
          NominateResult.refused,
          title: 'Game 2',
        );
        return [
          loaded(one, writing: (write: NominationWrite.nominate, id: 'g-2')),
          loaded(one, outcome: refused),
          loading(one, outcome: refused),
          loaded(one, outcome: refused),
        ];
      },
    );

    blocTest<EventNominationsBloc, EventNominationsState>(
      'dismissed clears the outcome and nothing else',
      build: () => build(serving()),
      seed: () => loaded(
        one,
        outcome: const WithdrawOutcome(WithdrawResult.refused, title: 'Game 1'),
      ),
      act: (bloc) => bloc.add(const EventNominationsOutcomeDismissed()),
      expect: () => [loaded(one)],
    );

    blocTest<EventNominationsBloc, EventNominationsState>(
      'dismissed with none emits nothing',
      build: () => build(serving()),
      seed: () => loaded(one),
      act: (bloc) => bloc.add(const EventNominationsOutcomeDismissed()),
      expect: () => <EventNominationsState>[],
    );
  });

  group('closing', () {
    test('nothing is emitted after close', () async {
      final reads = _Held<NominationsRequest, List<EventNomination>>();
      final sends = _Held<NominateRequest, EventNomination>();
      final bloc = build(
        serving(nominations: reads.call, nominated: sends.call),
      );
      final states = record(bloc);
      final errors = <Object>[];
      final watching = bloc.stream.listen(null, onError: errors.add);
      addTearDown(watching.cancel);

      bloc
        ..add(const EventNominationsRequested('e-1'))
        ..add(_nominate(2));
      await pumpEventQueue();
      final before = List.of(states);
      expect(before, isNotEmpty);

      // The screen leaves while both are out.
      await bloc.close();
      reads.answer(0, one);
      // A gone would read the nominations again.
      sends.fail(0, _gone);
      await pumpEventQueue();

      expect(states, before);
      expect(errors, isEmpty);
      expect(calls, unorderedEquals(['read', 'nominate']));
    });

    test('a vote answered after close sends no single read', () async {
      final votes = _Held<CastVoteRequest, void>();
      final bloc = build(serving(voteCast: votes.call));
      final states = record(bloc);

      bloc.add(_vote(n2));
      await pumpEventQueue();
      await bloc.close();
      votes.answer(0, null);
      await pumpEventQueue();

      expect(states, [
        const EventNominationsState(
          writing: (write: NominationWrite.vote, id: 'n-2'),
        ),
      ]);
      expect(calls, ['vote']);
    });

    test("a vote's single read answered after close emits nothing", () async {
      final reads = _Held<NominationRequest, EventNomination>();
      final bloc = build(serving(nomination: reads.call));
      final states = record(bloc);

      bloc.add(_vote(n2));
      await pumpEventQueue();
      await bloc.close();
      reads.answer(0, _votedOn(n2, VoteType.forGame));
      await pumpEventQueue();

      expect(states, [
        const EventNominationsState(
          writing: (write: NominationWrite.vote, id: 'n-2'),
        ),
      ]);
    });
  });
}
