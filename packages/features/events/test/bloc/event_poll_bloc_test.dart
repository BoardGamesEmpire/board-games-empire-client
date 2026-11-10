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

/// Votes that wait for the test to answer them, in the order they were sent.
final class _HeldVotes {
  final List<EventVoteRequest> _requests = [];
  final List<Completer<AvailabilityVote>> _replies = [];

  Future<AvailabilityVote> call(EventVoteRequest request) {
    final reply = Completer<AvailabilityVote>();
    _requests.add(request);
    _replies.add(reply);
    return reply.future;
  }

  /// Answers the [index]th vote sent: the server took it.
  void answer(int index) =>
      _replies[index].complete(_voteFor(_requests[index]));

  /// Answers the [index]th vote sent with [error].
  void fail(int index, Object error) => _replies[index].completeError(error);
}

/// Poll reads that wait for the test to answer them, in the order they were
/// sent.
final class _HeldReads {
  final List<Completer<AvailabilitySummary>> _replies = [];

  Future<AvailabilitySummary> call(String eventId) {
    final reply = Completer<AvailabilitySummary>();
    _replies.add(reply);
    return reply.future;
  }

  void answer(int index, AvailabilitySummary summary) =>
      _replies[index].complete(summary);

  void fail(int index, Object error) => _replies[index].completeError(error);
}

const _conflict = EventWriteConflictException('moved', statusCode: 400);
const _refused = EventWriteRefusedException('no', statusCode: 403);
const _gone = EventRemoteNotFoundException('gone', statusCode: 404);
const _forbidden = EventRemoteForbiddenException('hidden', statusCode: 403);
const _offline = EventRemoteTransientException('offline');
const _rejected = EventRemotePermanentException('bad', statusCode: 400);

const AvailabilityResponse _available = AvailabilityResponse.available;
const AvailabilityResponse _maybe = AvailabilityResponse.maybe;
const AvailabilityResponse _unavailable = AvailabilityResponse.unavailable;

const _idle = EventPollState();
const _loading = EventPollState(load: EventPollLoad.loading);

/// A summary in which the viewer, attendee `a-1`, answered each date as
/// [answers] says, and nobody else answered.
AvailabilitySummary _summaryOf(Map<String, AvailabilityResponse> answers) =>
    AvailabilitySummary(
      occurrences: [
        for (final MapEntry(key: occurrenceId, value: response)
            in answers.entries)
          OccurrenceAvailability(
            occurrenceId: occurrenceId,
            available: response == _available ? 1 : 0,
            maybe: response == _maybe ? 1 : 0,
            unavailable: response == _unavailable ? 1 : 0,
            voters: [
              AvailabilityVoter(
                attendeeId: 'a-1',
                response: response,
                eligible: true,
              ),
            ],
          ),
      ],
    );

/// The vote the server holds once it has taken [request].
AvailabilityVote _voteFor(EventVoteRequest request) => AvailabilityVote(
  id: 'v-${request.occurrenceId}',
  occurrenceId: request.occurrenceId,
  attendeeId: 'a-1',
  response: request.response,
  createdAt: DateTime.utc(2026, 10, 30),
  updatedAt: DateTime.utc(2026, 10, 30),
);

/// What a vote of [response] on the date `d-1` of the event `e-1` sent.
EventVoteRequest _sent(AvailabilityResponse response, [String date = 'd-1']) =>
    (eventId: 'e-1', occurrenceId: date, response: response);

/// A vote of [response] on [date] of the event `e-1`.
EventPollVoted _tap(AvailabilityResponse response, [String date = 'd-1']) =>
    EventPollVoted('e-1', date, response);

/// How a vote ended, as the bloc announces it.
EventActionOutcome _ended(EventActionResult result, [Object? error]) =>
    EventActionOutcome(
      action: EventAction.voteAvailability,
      result: result,
      error: error,
    );

/// The availability poll on the event detail screen (#507). The summary is
/// read whole and never cached. The viewer's votes go straight to the
/// server, dates together, and on one date the latest tap wins.
void main() {
  late _MockBgeLogger logger;

  /// What the bloc called, in order, where a test records it.
  late List<String> calls;

  setUp(() {
    logger = _MockBgeLogger();
    calls = [];
  });

  /// A server whose votes answer as [voted] does and whose poll reads
  /// answer as [summary] does, each recorded in [calls]. A read answers an
  /// empty summary unless a test says otherwise.
  FakeEventRemote serving({
    FutureOr<AvailabilityVote> Function(EventVoteRequest request) voted =
        _voteFor,
    FutureOr<AvailabilitySummary> Function(String eventId)? summary,
  }) => FakeEventRemote.detail(
    (_) => throw UnimplementedError('the poll reads no event'),
    voted: (request) {
      calls.add('vote');
      return voted(request);
    },
    summary: (eventId) {
      calls.add('summary');
      return summary == null ? _summaryOf(const {}) : summary(eventId);
    },
  );

  EventPollBloc build(
    FakeEventRemote remote, {
    Future<bool> Function()? confirmSession,
  }) => EventPollBloc(
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
  List<EventPollState> record(EventPollBloc bloc) {
    final states = <EventPollState>[];
    final subscription = bloc.stream.listen(states.add);
    addTearDown(subscription.cancel);
    return states;
  }

  EventPollState loaded(
    AvailabilitySummary summary, {
    Map<String, AvailabilityResponse> pending = const {},
    EventActionOutcome? outcome,
  }) => EventPollState(
    load: EventPollLoad.loaded,
    summary: summary,
    pending: pending,
    outcome: outcome,
  );

  /// A read that ended failed, keeping [summary].
  EventPollState failed({
    AvailabilitySummary? summary,
    Map<String, AvailabilityResponse> pending = const {},
    EventActionOutcome? outcome,
  }) => EventPollState(
    load: EventPollLoad.failed,
    summary: summary,
    pending: pending,
    outcome: outcome,
    refreshFailed: true,
  );

  void verifyWarnings(int count) => verify(
    () => logger.warn(
      any(),
      error: any(named: 'error'),
      stackTrace: any(named: 'stackTrace'),
    ),
  ).called(count);

  final one = _summaryOf(const {'d-1': _available});
  final two = _summaryOf(const {'d-1': _maybe});

  test('starts idle, with nothing pending', () {
    final bloc = build(serving());
    addTearDown(bloc.close);

    expect(bloc.state, _idle);
  });

  group('reads', () {
    test('a request reads the summary and loads', () async {
      final remote = serving(summary: (_) => one);
      final bloc = build(remote);
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(const EventPollRequested('e-1'));
      await pumpEventQueue();

      expect(remote.summaryRequests, ['e-1']);
      expect(states, [_loading, loaded(one)]);
    });

    blocTest<EventPollBloc, EventPollState>(
      'a forbidden read is hidden',
      build: () => build(serving(summary: (_) => throw _forbidden)),
      seed: () => loaded(one),
      act: (bloc) => bloc.add(const EventPollRequested('e-1')),
      // The viewer may not read the votes now, so the last summary goes
      // with them.
      expect: () => [
        EventPollState(load: EventPollLoad.loading, summary: one),
        const EventPollState(load: EventPollLoad.hidden),
      ],
    );

    blocTest<EventPollBloc, EventPollState>(
      'a failed read keeps the last summary and fails',
      build: () => build(serving(summary: (_) => throw _offline)),
      seed: () => loaded(one),
      act: (bloc) => bloc.add(const EventPollRequested('e-1')),
      expect: () => [
        EventPollState(load: EventPollLoad.loading, summary: one),
        failed(summary: one),
      ],
      verify: (_) => verifyWarnings(1),
    );

    blocTest<EventPollBloc, EventPollState>(
      'a read that finds the event gone says so, with the summary cleared',
      build: () => build(serving(summary: (_) => throw _gone)),
      seed: () => loaded(one),
      act: (bloc) => bloc.add(const EventPollRequested('e-1')),
      expect: () => [
        EventPollState(load: EventPollLoad.loading, summary: one),
        const EventPollState(load: EventPollLoad.gone),
      ],
    );

    blocTest<EventPollBloc, EventPollState>(
      'a read after a refusal stays refused until it answers otherwise',
      build: () => build(serving(summary: (_) => one)),
      seed: () => const EventPollState(load: EventPollLoad.hidden),
      act: (bloc) => bloc.add(const EventPollRequested('e-1')),
      // No loading between, so the refused viewer sees nothing change.
      expect: () => [loaded(one)],
    );

    blocTest<EventPollBloc, EventPollState>(
      'a read after a gone that is gone again emits nothing',
      build: () => build(serving(summary: (_) => throw _gone)),
      seed: () => const EventPollState(load: EventPollLoad.gone),
      act: (bloc) => bloc.add(const EventPollRequested('e-1')),
      expect: () => <EventPollState>[],
    );

    test('two requests during a read run one more read, not two', () async {
      final reads = _HeldReads();
      final remote = serving(summary: reads.call);
      final bloc = build(remote);
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(const EventPollRequested('e-1'));
      await pumpEventQueue();
      bloc
        ..add(const EventPollRequested('e-1'))
        ..add(const EventPollRequested('e-1'));
      await pumpEventQueue();

      // Never two at once.
      expect(remote.summaryRequests, ['e-1']);

      reads.answer(0, one);
      await pumpEventQueue();

      expect(remote.summaryRequests, ['e-1', 'e-1']);

      reads.answer(1, two);
      await pumpEventQueue();

      expect(remote.summaryRequests, hasLength(2));
      expect(states, [
        _loading,
        loaded(one),
        EventPollState(load: EventPollLoad.loading, summary: one),
        loaded(two),
      ]);
    });
  });

  group('after a failed read', () {
    // So a screen can keep its failed banner, and the retry in it, in place
    // while the next read runs.

    /// A bloc whose first read loaded `one` and whose second failed, each
    /// answered through [reads], and its server. Its session is asked
    /// through [confirmSession], if any.
    Future<(EventPollBloc, FakeEventRemote)> failedOnce(
      _HeldReads reads, {
      Future<bool> Function()? confirmSession,
    }) async {
      final remote = serving(summary: reads.call);
      final bloc = build(remote, confirmSession: confirmSession);
      addTearDown(bloc.close);

      bloc.add(const EventPollRequested('e-1'));
      await pumpEventQueue();
      reads.answer(0, one);
      await pumpEventQueue();
      bloc.add(const EventPollRequested('e-1'));
      await pumpEventQueue();
      reads.fail(1, _offline);
      await pumpEventQueue();

      expect(bloc.state, failed(summary: one));
      return (bloc, remote);
    }

    for (final (name, end, ended)
        in <(String, void Function(_HeldReads), EventPollState)>[
          (
            'a read that succeeds clears it',
            (reads) => reads.answer(2, two),
            EventPollState(load: EventPollLoad.loaded, summary: two),
          ),
          (
            'a read that fails keeps it',
            (reads) => reads.fail(2, _offline),
            EventPollState(
              load: EventPollLoad.failed,
              summary: one,
              refreshFailed: true,
            ),
          ),
        ]) {
      test('the failure stays while the next read runs, and $name', () async {
        final reads = _HeldReads();
        final (bloc, _) = await failedOnce(reads);
        final states = record(bloc);

        bloc.add(const EventPollRequested('e-1'));
        await pumpEventQueue();

        // The read the screen makes after a detail read: nobody asked for
        // it, so it isn't a refresh.
        expect(
          bloc.state,
          EventPollState(
            load: EventPollLoad.loading,
            summary: one,
            refreshFailed: true,
          ),
        );

        end(reads);
        await pumpEventQueue();

        expect(states.last, ended);
      });
    }

    test('a retry says so from its request until its read ends', () async {
      final reads = _HeldReads();
      Completer<bool>? asked;
      final (bloc, remote) = await failedOnce(
        reads,
        confirmSession: () => asked?.future ?? Future.value(true),
      );
      final session = asked = Completer();
      final states = record(bloc);

      bloc.add(const EventPollRetryRequested('e-1'));
      await pumpEventQueue();

      // At once, before the session has answered: the retry is under way.
      expect(states, [
        EventPollState(
          load: EventPollLoad.failed,
          summary: one,
          refreshFailed: true,
          refreshing: true,
        ),
      ]);
      expect(remote.summaryRequests, hasLength(2));

      session.complete(true);
      await pumpEventQueue();
      reads.fail(2, _offline);
      await pumpEventQueue();

      expect(states.sublist(1), [
        EventPollState(
          load: EventPollLoad.loading,
          summary: one,
          refreshFailed: true,
          refreshing: true,
        ),
        failed(summary: one),
      ]);
    });

    test('a retry while a read is out is under way until the read after it '
        'ends', () async {
      final reads = _HeldReads();
      final (bloc, remote) = await failedOnce(reads);
      final states = record(bloc);

      bloc.add(const EventPollRequested('e-1'));
      await pumpEventQueue();
      bloc.add(const EventPollRetryRequested('e-1'));
      await pumpEventQueue();
      reads.answer(2, two);
      await pumpEventQueue();

      // The read that was out went before the retry, so the retry's own
      // read follows it.
      expect(remote.summaryRequests, hasLength(4));

      reads.answer(3, one);
      await pumpEventQueue();

      expect(states, [
        EventPollState(
          load: EventPollLoad.loading,
          summary: one,
          refreshFailed: true,
        ),
        EventPollState(
          load: EventPollLoad.loading,
          summary: one,
          refreshFailed: true,
          refreshing: true,
        ),
        EventPollState(
          load: EventPollLoad.loaded,
          summary: two,
          refreshing: true,
        ),
        EventPollState(
          load: EventPollLoad.loading,
          summary: two,
          refreshing: true,
        ),
        loaded(one),
      ]);
    });

    test('a retry whose session says no ends failed again', () async {
      final reads = _HeldReads();
      var confirmed = true;
      final (bloc, remote) = await failedOnce(
        reads,
        confirmSession: () async => confirmed,
      );
      confirmed = false;
      final states = record(bloc);

      bloc.add(const EventPollRetryRequested('e-1'));
      await pumpEventQueue();

      expect(remote.summaryRequests, hasLength(2));
      expect(states, [
        EventPollState(
          load: EventPollLoad.failed,
          summary: one,
          refreshFailed: true,
          refreshing: true,
        ),
        failed(summary: one),
      ]);
    });
  });

  group('votes', () {
    test('a vote shows as pending at once, then one read follows', () async {
      final votes = _HeldVotes();
      final remote = serving(voted: votes.call, summary: (_) => one);
      final bloc = build(remote);
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(_tap(_available));
      await pumpEventQueue();

      expect(remote.voteRequests, [_sent(_available)]);
      expect(remote.summaryRequests, isEmpty);
      expect(states, [
        const EventPollState(pending: {'d-1': _available}),
      ]);

      votes.answer(0);
      await pumpEventQueue();

      expect(remote.summaryRequests, ['e-1']);
      expect(states, [
        const EventPollState(pending: {'d-1': _available}),
        const EventPollState(
          load: EventPollLoad.loading,
          pending: {'d-1': _available},
        ),
        // The read went out after the vote was answered, so it holds the
        // answer.
        loaded(one),
      ]);
    });

    test(
      'votes on two dates go out together, and one read follows both',
      () async {
        final votes = _HeldVotes();
        final both = _summaryOf(const {'d-1': _available, 'd-2': _maybe});
        final remote = serving(voted: votes.call, summary: (_) => both);
        final bloc = build(remote);
        addTearDown(bloc.close);

        bloc
          ..add(_tap(_available))
          ..add(_tap(_maybe, 'd-2'));
        await pumpEventQueue();

        // Both are out, and neither has been answered.
        expect(remote.voteRequests, [_sent(_available), _sent(_maybe, 'd-2')]);
        expect(bloc.state.pending, {'d-1': _available, 'd-2': _maybe});

        votes.answer(1);
        await pumpEventQueue();

        // The first date's vote is still out.
        expect(remote.summaryRequests, isEmpty);

        votes.answer(0);
        await pumpEventQueue();

        expect(remote.summaryRequests, ['e-1']);
        expect(bloc.state, loaded(both));
      },
    );

    test('a second tap on a date while its vote is out is sent after it, and '
        'only the last', () async {
      final votes = _HeldVotes();
      final last = _summaryOf(const {'d-1': _unavailable});
      final remote = serving(voted: votes.call, summary: (_) => last);
      final bloc = build(remote);
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(_tap(_available));
      await pumpEventQueue();
      bloc.add(_tap(_maybe));
      await pumpEventQueue();
      bloc.add(_tap(_unavailable));
      await pumpEventQueue();

      // The first is still out, so the others wait.
      expect(remote.voteRequests, [_sent(_available)]);

      votes.answer(0);
      await pumpEventQueue();

      // Maybe was replaced before it could go.
      expect(remote.voteRequests, [_sent(_available), _sent(_unavailable)]);
      expect(remote.summaryRequests, isEmpty);

      votes.answer(1);
      await pumpEventQueue();

      expect(remote.voteRequests, hasLength(2));
      expect(remote.summaryRequests, ['e-1']);
      expect(states, [
        const EventPollState(pending: {'d-1': _available}),
        const EventPollState(pending: {'d-1': _maybe}),
        // From the third tap on, the date reads Unavailable until the read
        // that follows holds it.
        const EventPollState(pending: {'d-1': _unavailable}),
        const EventPollState(
          load: EventPollLoad.loading,
          pending: {'d-1': _unavailable},
        ),
        loaded(last),
      ]);
    });

    for (final (name, error, result) in <(String, Object, EventActionResult)>[
      (
        'a 400 is changed and drops the pending answer',
        _conflict,
        EventActionResult.changed,
      ),
      ('a 403 is refused', _refused, EventActionResult.refused),
      ('a 404 is gone', _gone, EventActionResult.gone),
    ]) {
      test(name, () async {
        final now = _summaryOf(const {});
        final remote = serving(voted: (_) => throw error, summary: (_) => now);
        final bloc = build(remote);
        addTearDown(bloc.close);
        final states = record(bloc);

        bloc.add(_tap(_available));
        await pumpEventQueue();

        final outcome = _ended(result, error);
        expect(states, [
          const EventPollState(pending: {'d-1': _available}),
          EventPollState(outcome: outcome),
          // The poll is read again, as after any run of votes.
          EventPollState(load: EventPollLoad.loading, outcome: outcome),
          loaded(now, outcome: outcome),
        ]);
        // And the screen reads the event again, for the date as it stands.
        expect(outcome.rereads, isTrue);
        expect(remote.summaryRequests, ['e-1']);
      });
    }

    for (final (kind, error) in <(String, Object)>[
      ('transient', _offline),
      ('permanent', _rejected),
    ]) {
      test('a $kind failure is failed and does not re-read', () async {
        final remote = serving(voted: (_) => throw error, summary: (_) => one);
        final bloc = build(remote);
        addTearDown(bloc.close);
        final states = record(bloc);

        bloc.add(_tap(_available));
        await pumpEventQueue();

        final outcome = _ended(EventActionResult.failed, error);
        expect(states, [
          const EventPollState(pending: {'d-1': _available}),
          EventPollState(outcome: outcome),
          EventPollState(load: EventPollLoad.loading, outcome: outcome),
          loaded(one, outcome: outcome),
        ]);
        // A vote changes no event status, so the event isn't read again.
        // The poll is, above.
        expect(outcome.rereads, isFalse);
        verifyWarnings(1);
      });
    }

    test(
      "a done vote's outcome is not emitted, and doesn't re-read the event",
      () async {
        final bloc = build(serving(summary: (_) => one));
        addTearDown(bloc.close);
        final states = record(bloc);

        bloc.add(_tap(_available));
        await pumpEventQueue();

        expect(states.map((state) => state.outcome), everyElement(isNull));
        expect(states.last, loaded(one));
        expect(_ended(EventActionResult.done).rereads, isFalse);
      },
    );
  });

  group('a queued answer', () {
    for (final (kind, error) in <(String, Object)>[
      ('transient', _offline),
      ('permanent', _rejected),
    ]) {
      test('is sent after a $kind failure, which is not announced', () async {
        // The latest tap's own end decides the banner.
        final votes = _HeldVotes();
        final last = _summaryOf(const {'d-1': _maybe});
        final remote = serving(voted: votes.call, summary: (_) => last);
        final bloc = build(remote);
        addTearDown(bloc.close);
        final states = record(bloc);

        bloc.add(_tap(_available));
        await pumpEventQueue();
        bloc.add(_tap(_maybe));
        await pumpEventQueue();
        votes.fail(0, error);
        await pumpEventQueue();

        expect(remote.voteRequests, [_sent(_available), _sent(_maybe)]);
        expect(bloc.state, const EventPollState(pending: {'d-1': _maybe}));

        votes.answer(1);
        await pumpEventQueue();

        expect(states.map((state) => state.outcome), everyElement(isNull));
        expect(bloc.state, loaded(last));
      });
    }

    for (final (error, result) in <(Object, EventActionResult)>[
      (_conflict, EventActionResult.changed),
      (_refused, EventActionResult.refused),
      (_gone, EventActionResult.gone),
    ]) {
      test('is dropped when the vote before it is ${result.name}', () async {
        final votes = _HeldVotes();
        final now = _summaryOf(const {});
        final remote = serving(voted: votes.call, summary: (_) => now);
        final bloc = build(remote);
        addTearDown(bloc.close);
        final states = record(bloc);

        bloc.add(_tap(_available));
        await pumpEventQueue();
        bloc.add(_tap(_maybe));
        await pumpEventQueue();
        votes.fail(0, error);
        await pumpEventQueue();

        final outcome = _ended(result, error);
        expect(remote.voteRequests, [_sent(_available)]);
        expect(states, [
          const EventPollState(pending: {'d-1': _available}),
          const EventPollState(pending: {'d-1': _maybe}),
          EventPollState(outcome: outcome),
          EventPollState(load: EventPollLoad.loading, outcome: outcome),
          loaded(now, outcome: outcome),
        ]);
      });
    }

    test('is dropped when the session says no to the vote before it', () async {
      final asked = Completer<bool>();
      var first = true;
      final remote = serving();
      final bloc = build(
        remote,
        confirmSession: () {
          calls.add('session');
          if (!first) return Future.value(false);
          first = false;
          return asked.future;
        },
      );
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(_tap(_available));
      await pumpEventQueue();
      bloc.add(_tap(_maybe));
      await pumpEventQueue();
      asked.complete(false);
      await pumpEventQueue();

      // The vote's session, then the read's: nothing went out.
      expect(calls, ['session', 'session']);
      expect(remote.voteRequests, isEmpty);
      final outcome = _ended(EventActionResult.failed);
      expect(states, [
        const EventPollState(pending: {'d-1': _available}),
        const EventPollState(pending: {'d-1': _maybe}),
        EventPollState(outcome: outcome),
        failed(outcome: outcome),
      ]);
    });

    test('asks the session again before it is sent', () async {
      final votes = _HeldVotes();
      final remote = serving(voted: votes.call);
      final bloc = build(remote, confirmSession: answering([true, false]));
      addTearDown(bloc.close);

      bloc.add(_tap(_available));
      await pumpEventQueue();
      bloc.add(_tap(_maybe));
      await pumpEventQueue();
      votes.answer(0);
      await pumpEventQueue();

      expect(calls, ['session', 'vote', 'session', 'session']);
      expect(remote.voteRequests, [_sent(_available)]);
      expect(bloc.state, failed(outcome: _ended(EventActionResult.failed)));
    });
  });

  test(
    'the session is asked before a vote and a read, and a no sends nothing',
    () async {
      final remote = serving();
      final bloc = build(remote, confirmSession: answering([false]));
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(_tap(_available));
      await pumpEventQueue();

      expect(calls, ['session', 'session']);
      expect(remote.voteRequests, isEmpty);
      expect(remote.summaryRequests, isEmpty);
      // No error: nothing reached the server. The read the run of votes
      // asked for is failed too, as the detail's read is.
      final outcome = _ended(EventActionResult.failed);
      expect(states, [
        const EventPollState(pending: {'d-1': _available}),
        EventPollState(outcome: outcome),
        failed(outcome: outcome),
      ]);
      expect(outcome.rereads, isFalse);
    },
  );

  group('the session', () {
    test('is asked before a vote and before a read', () async {
      final bloc = build(
        serving(summary: (_) => one),
        confirmSession: answering([true]),
      );
      addTearDown(bloc.close);

      bloc.add(_tap(_available));
      await pumpEventQueue();

      expect(calls, ['session', 'vote', 'session', 'summary', 'session']);
    });

    for (final (name, summary)
        in <(String, AvailabilitySummary Function(String))>[
          ('a summary', (_) => two),
          ('a refusal', (_) => throw _forbidden),
          ('a gone', (_) => throw _gone),
        ]) {
      blocTest<EventPollBloc, EventPollState>(
        "$name answered after the session moved is another user's, and the "
        'read is failed, keeping the last summary',
        build: () => build(
          serving(summary: summary),
          confirmSession: answering([true, false]),
        ),
        seed: () => loaded(one),
        act: (bloc) => bloc.add(const EventPollRequested('e-1')),
        skip: 1,
        expect: () => [failed(summary: one)],
        verify: (_) => expect(calls, ['session', 'summary', 'session']),
      );
    }

    blocTest<EventPollBloc, EventPollState>(
      'a read whose session says no is failed, with no error, keeping the '
      'last summary',
      // As the detail's read is: a page waiting on it would otherwise wait
      // for ever, and a retry can ask again.
      build: () => build(serving(), confirmSession: answering([false])),
      seed: () => loaded(one, pending: const {'d-2': _maybe}),
      act: (bloc) => bloc.add(const EventPollRequested('e-1')),
      expect: () => [
        failed(summary: one, pending: const {'d-2': _maybe}),
      ],
      verify: (_) {
        expect(calls, ['session']);
        // Nothing went wrong on the wire: the no is logged, not warned of.
        verifyNever(
          () => logger.warn(
            any(),
            error: any(named: 'error'),
            stackTrace: any(named: 'stackTrace'),
          ),
        );
      },
    );

    test('a session that throws is a no, and logged', () async {
      final remote = serving();
      final bloc = build(
        remote,
        confirmSession: () async => throw StateError('no answer'),
      );
      addTearDown(bloc.close);

      bloc.add(_tap(_available));
      await pumpEventQueue();

      expect(remote.voteRequests, isEmpty);
      expect(remote.summaryRequests, isEmpty);
      // The vote is failed, and so is the read after it.
      expect(bloc.state, failed(outcome: _ended(EventActionResult.failed)));
      // The vote's, then the read's.
      verifyWarnings(2);
    });
  });

  test('pending clears only when a read that started after the vote ended '
      'succeeds', () async {
    final votes = _HeldVotes();
    final reads = _HeldReads();
    final remote = serving(voted: votes.call, summary: reads.call);
    final bloc = build(remote);
    addTearDown(bloc.close);
    final states = record(bloc);

    bloc.add(_tap(_available));
    await pumpEventQueue();
    // The screen reads the poll after a detail read, while the vote is out.
    bloc.add(const EventPollRequested('e-1'));
    await pumpEventQueue();
    votes.answer(0);
    await pumpEventQueue();

    // The run of votes has settled, but a read is out, so its read waits.
    expect(remote.summaryRequests, ['e-1']);

    final before = _summaryOf(const {});
    reads.answer(0, before);
    await pumpEventQueue();

    // That read went out before the vote was answered, so it may not hold
    // it. The read the run of votes asked for goes out next.
    expect(states.sublist(states.length - 2), [
      loaded(before, pending: const {'d-1': _available}),
      EventPollState(
        load: EventPollLoad.loading,
        summary: before,
        pending: const {'d-1': _available},
      ),
    ]);
    expect(remote.summaryRequests, ['e-1', 'e-1']);

    reads.fail(1, _offline);
    await pumpEventQueue();

    // A failed read holds nothing.
    expect(
      bloc.state,
      failed(summary: before, pending: const {'d-1': _available}),
    );

    bloc.add(const EventPollRequested('e-1'));
    await pumpEventQueue();
    reads.answer(2, one);
    await pumpEventQueue();

    expect(bloc.state, loaded(one));
  });

  test('a read keeps a date pending that was tapped again while it was '
      'out', () async {
    final votes = _HeldVotes();
    final reads = _HeldReads();
    final remote = serving(voted: votes.call, summary: reads.call);
    final bloc = build(remote);
    addTearDown(bloc.close);

    bloc.add(_tap(_available));
    await pumpEventQueue();
    votes.answer(0);
    await pumpEventQueue();
    // The read the vote asked for is out, and the date is tapped again.
    bloc.add(_tap(_maybe));
    await pumpEventQueue();

    reads.answer(0, one);
    await pumpEventQueue();

    // The read holds the first answer, not the one still out.
    expect(bloc.state, loaded(one, pending: const {'d-1': _maybe}));

    votes.answer(1);
    await pumpEventQueue();
    reads.answer(1, two);
    await pumpEventQueue();

    expect(remote.summaryRequests, hasLength(2));
    expect(bloc.state, loaded(two));
  });

  group('the outcome', () {
    test('a vote re-reads the event only when changed, gone or refused', () {
      expect(_ended(EventActionResult.changed, _conflict).rereads, isTrue);
      expect(_ended(EventActionResult.gone, _gone).rereads, isTrue);
      expect(_ended(EventActionResult.refused, _refused).rereads, isTrue);

      // A vote changes no event status: the poll bloc reads the poll again
      // after a run of votes, and the event needs no read.
      expect(_ended(EventActionResult.done).rereads, isFalse);
      expect(_ended(EventActionResult.failed, _offline).rereads, isFalse);
      expect(_ended(EventActionResult.failed, _rejected).rereads, isFalse);
      expect(_ended(EventActionResult.failed).rereads, isFalse);
      expect(_ended(EventActionResult.partlyDone).rereads, isFalse);
    });

    blocTest<EventPollBloc, EventPollState>(
      'a tap clears the last outcome',
      // The banner described an earlier vote.
      build: () => build(serving(voted: _HeldVotes().call)),
      seed: () =>
          EventPollState(outcome: _ended(EventActionResult.failed, _offline)),
      act: (bloc) => bloc.add(_tap(_available)),
      expect: () => [
        const EventPollState(pending: {'d-1': _available}),
      ],
    );

    blocTest<EventPollBloc, EventPollState>(
      'dismissing clears the outcome, and keeps what is pending',
      build: () => build(serving()),
      seed: () => EventPollState(
        pending: const {'d-2': _maybe},
        outcome: _ended(EventActionResult.refused, _refused),
      ),
      act: (bloc) => bloc.add(const EventPollOutcomeDismissed()),
      expect: () => [
        const EventPollState(pending: {'d-2': _maybe}),
      ],
    );

    blocTest<EventPollBloc, EventPollState>(
      'dismissing does nothing while there is no outcome',
      build: () => build(serving()),
      act: (bloc) => bloc.add(const EventPollOutcomeDismissed()),
      expect: () => <EventPollState>[],
    );
  });

  group('closing', () {
    for (final (name, answer) in <(String, void Function(_HeldVotes))>[
      ('done', (votes) => votes.answer(0)),
      ('400', (votes) => votes.fail(0, _conflict)),
    ]) {
      test('a vote answered after close emits nothing ($name)', () async {
        final votes = _HeldVotes();
        final remote = serving(voted: votes.call);
        final bloc = build(remote);
        final states = record(bloc);

        bloc.add(_tap(_available));
        await pumpEventQueue();
        // The screen leaves while the vote is out.
        await bloc.close();
        answer(votes);
        await pumpEventQueue();

        expect(states, [
          const EventPollState(pending: {'d-1': _available}),
        ]);
        expect(remote.summaryRequests, isEmpty);
      });
    }

    test('a bloc that starts closing as a vote is answered emits nothing '
        'more', () async {
      // Close starts as the server answers, before bloc's own close has
      // cancelled the handler. The bloc's own check keeps the outcome off a
      // closing stream.
      late EventPollBloc bloc;
      Future<void>? closing;
      final remote = serving(
        voted: (_) {
          closing = bloc.close();
          throw _conflict;
        },
      );
      bloc = build(remote);
      final states = record(bloc);

      bloc.add(_tap(_available));
      await pumpEventQueue();
      await closing;

      expect(states, [
        const EventPollState(pending: {'d-1': _available}),
      ]);
      expect(remote.summaryRequests, isEmpty);
    });

    test('a queued answer is still sent after close', () async {
      // It is the answer the viewer last saw on the date.
      final votes = _HeldVotes();
      final remote = serving(voted: votes.call);
      final bloc = build(remote);
      final states = record(bloc);

      bloc.add(_tap(_available));
      await pumpEventQueue();
      bloc.add(_tap(_maybe));
      await pumpEventQueue();
      await bloc.close();
      votes.answer(0);
      await pumpEventQueue();

      expect(remote.voteRequests, [_sent(_available), _sent(_maybe)]);
      expect(states, [
        const EventPollState(pending: {'d-1': _available}),
        const EventPollState(pending: {'d-1': _maybe}),
      ]);
    });

    test('a read answered after close emits nothing', () async {
      final reads = _HeldReads();
      final bloc = build(serving(summary: reads.call));
      final states = record(bloc);

      bloc.add(const EventPollRequested('e-1'));
      await pumpEventQueue();
      await bloc.close();
      reads.answer(0, one);
      await pumpEventQueue();

      expect(states, [_loading]);
    });
  });
}
