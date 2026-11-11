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

const _alreadyOffered = EventWriteConflictException(
  'already',
  statusCode: 409,
);
const _leftCollection = EventWriteConflictException('left', statusCode: 400);
const _stillSupplies = EventWriteConflictException(
  'supplies',
  statusCode: 409,
);
const _oddConflict = EventWriteConflictException('odd', statusCode: 422);
const _refused = EventWriteRefusedException('no', statusCode: 403);
const _gone = EventRemoteNotFoundException('gone', statusCode: 404);
const _forbidden = EventRemoteForbiddenException('hidden', statusCode: 403);
const _offline = EventRemoteTransientException('offline');

const _ids = ['a-1', 'a-2'];
const _laterIds = ['a-1', 'a-2', 'a-3'];

const _idle = EventGamesState();
const _loading = EventGamesState(load: EventGamesLoad.loading);

/// The game `g-[n]`, offered by `a-1` from their entry `c-[n]`.
OfferedGame _game(int n) => OfferedGame(
  id: 'g-$n',
  attendeeId: 'a-1',
  collectionId: 'c-$n',
  platformGameId: 'pg-$n',
  gameId: 'game-$n',
  title: 'Game $n',
  platformName: 'Tabletop',
);

/// The offered game a send of [request] answers with.
OfferedGame _offeredFor(OfferGameRequest request) => OfferedGame(
  id: 'g-${request.collectionId}',
  attendeeId: request.attendeeId,
  collectionId: request.collectionId,
  platformGameId: 'pg',
  gameId: 'game',
  title: 'Game',
  platformName: 'Tabletop',
);

/// Picks of the entries `c-1` to `c-[count]`.
List<OfferPick> _picks(int count) => [
  for (var n = 1; n <= count; n++)
    OfferPick(collectionId: 'c-$n', title: 'Game $n'),
];

/// An offer by `a-1` on the event `e-1` of [count] picks.
EventGamesOffered _offer(int count) =>
    EventGamesOffered('e-1', 'a-1', _picks(count), attendeeIds: _ids);

/// A take-back by `a-1` on the event `e-1` of [game].
EventGameTakenBack _takeBack(OfferedGame game) =>
    EventGameTakenBack('e-1', 'a-1', game, attendeeIds: _ids);

/// An offer run's end.
EventGamesOutcome _offerEnded(
  EventOfferResult result, {
  required int offered,
  required int notOffered,
}) => EventOfferOutcome(
  result: result,
  offered: offered,
  notOffered: notOffered,
);

/// A take-back's end, of [game]: named by its title, and by its id.
EventGamesOutcome _takeBackEnded(
  EventTakeBackResult result,
  OfferedGame game,
) => EventTakeBackOutcome(
  result: result,
  title: game.title,
  offeredGameId: game.id,
);

/// A pool read of the attendees [attendeeIds] of the event [eventId]. A
/// record compares its list by identity, so the fields are matched instead.
Matcher _poolRead(String eventId, List<String> attendeeIds) =>
    isA<GamesPoolRequest>()
        .having((request) => request.eventId, 'eventId', eventId)
        .having((request) => request.attendeeIds, 'attendeeIds', attendeeIds);

/// The games pool on an event's Games tab (#516). The pool is read whole and
/// never cached. The viewer's offers go one at a time, and a take-back is one
/// request.
void main() {
  late _MockBgeLogger logger;

  /// What the bloc called, in order, where a test records it.
  late List<String> calls;

  setUp(() {
    logger = _MockBgeLogger();
    calls = [];
  });

  /// A server whose pool reads, offers and take-backs answer as [pool],
  /// [offered] and [takenBack] do, each recorded in [calls]. A read answers
  /// an empty pool, an offer the offered game and a take-back done, unless a
  /// test says otherwise.
  FakeEventRemote serving({
    FutureOr<List<OfferedGame>> Function(GamesPoolRequest request)? pool,
    FutureOr<OfferedGame> Function(OfferGameRequest request) offered =
        _offeredFor,
    FutureOr<void> Function(TakeBackGameRequest request)? takenBack,
  }) => FakeEventRemote.detail(
    (_) => throw UnimplementedError('the pool reads no event'),
    pool: (request) {
      calls.add('pool');
      return pool == null ? const <OfferedGame>[] : pool(request);
    },
    offered: (request) {
      calls.add('offer');
      return offered(request);
    },
    takenBack: (request) {
      calls.add('takeBack');
      if (takenBack != null) return takenBack(request);
    },
  );

  EventGamesBloc build(
    FakeEventRemote remote, {
    Future<bool> Function()? confirmSession,
  }) => EventGamesBloc(
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
  List<EventGamesState> record(EventGamesBloc bloc) {
    final states = <EventGamesState>[];
    final subscription = bloc.stream.listen(states.add);
    addTearDown(subscription.cancel);
    return states;
  }

  EventGamesState loaded(
    List<OfferedGame> games, {
    EventGamesOutcome? outcome,
  }) => EventGamesState(
    load: EventGamesLoad.loaded,
    games: games,
    outcome: outcome,
  );

  /// A read that ended failed, keeping [games].
  EventGamesState failed({
    List<OfferedGame> games = const [],
    EventGamesOutcome? outcome,
  }) => EventGamesState(
    load: EventGamesLoad.failed,
    games: games,
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

  void verifyNoWarnings() => verifyNever(
    () => logger.warn(
      any(),
      error: any(named: 'error'),
      stackTrace: any(named: 'stackTrace'),
    ),
  );

  final one = [_game(1)];
  final two = [_game(1), _game(2)];

  test('starts idle, with nothing out', () {
    final bloc = build(serving());
    addTearDown(bloc.close);

    expect(bloc.state, _idle);
    expect(bloc.state.busy, isFalse);
  });

  group('reads', () {
    test(
      'a request reads the pool of the attendees it names and loads',
      () async {
        final remote = serving(pool: (_) => two);
        final bloc = build(remote);
        addTearDown(bloc.close);
        final states = record(bloc);

        bloc.add(const EventGamesRequested('e-1', _ids));
        await pumpEventQueue();

        expect(remote.poolRequests, [_poolRead('e-1', _ids)]);
        expect(states, [_loading, loaded(two)]);
      },
    );

    blocTest<EventGamesBloc, EventGamesState>(
      'a forbidden read is hidden, with the games cleared',
      build: () => build(serving(pool: (_) => throw _forbidden)),
      seed: () => loaded(one),
      act: (bloc) => bloc.add(const EventGamesRequested('e-1', _ids)),
      expect: () => [
        EventGamesState(load: EventGamesLoad.loading, games: one),
        const EventGamesState(load: EventGamesLoad.hidden),
      ],
    );

    blocTest<EventGamesBloc, EventGamesState>(
      'a read that finds the event gone says so, with the games cleared',
      build: () => build(serving(pool: (_) => throw _gone)),
      seed: () => loaded(one),
      act: (bloc) => bloc.add(const EventGamesRequested('e-1', _ids)),
      expect: () => [
        EventGamesState(load: EventGamesLoad.loading, games: one),
        const EventGamesState(load: EventGamesLoad.gone),
      ],
    );

    blocTest<EventGamesBloc, EventGamesState>(
      'a failed read keeps the last games and fails',
      build: () => build(serving(pool: (_) => throw _offline)),
      seed: () => loaded(one),
      act: (bloc) => bloc.add(const EventGamesRequested('e-1', _ids)),
      expect: () => [
        EventGamesState(load: EventGamesLoad.loading, games: one),
        failed(games: one),
      ],
      verify: (_) => verifyWarnings(1),
    );

    blocTest<EventGamesBloc, EventGamesState>(
      'a read after a refusal stays refused until it answers otherwise',
      build: () => build(serving(pool: (_) => one)),
      seed: () => const EventGamesState(load: EventGamesLoad.hidden),
      act: (bloc) => bloc.add(const EventGamesRequested('e-1', _ids)),
      // No loading between, so the refused viewer sees nothing change.
      expect: () => [loaded(one)],
    );

    // The event's own read settles a gone. A pool still not found once that
    // has read the event fine, as on a server without these routes, is a
    // failure the user can retry, not a wait for good.
    blocTest<EventGamesBloc, EventGamesState>(
      'a read after a gone that is gone again fails, with no games',
      build: () => build(serving(pool: (_) => throw _gone)),
      seed: () => const EventGamesState(load: EventGamesLoad.gone),
      act: (bloc) => bloc.add(const EventGamesRequested('e-1', _ids)),
      expect: () => [failed()],
    );

    blocTest<EventGamesBloc, EventGamesState>(
      'a read after a gone that is forbidden is hidden',
      build: () => build(serving(pool: (_) => throw _forbidden)),
      seed: () => const EventGamesState(load: EventGamesLoad.gone),
      act: (bloc) => bloc.add(const EventGamesRequested('e-1', _ids)),
      expect: () => [const EventGamesState(load: EventGamesLoad.hidden)],
    );

    test('a pool that keeps answering 404 reads twice from a retry, and '
        'stops', () async {
      final remote = serving(pool: (_) => throw _gone);
      final bloc = build(remote);
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(const EventGamesRequested('e-1', _ids));
      await pumpEventQueue();
      expect(bloc.state.load, EventGamesLoad.gone);

      // The screen reads the event, which reads fine, and asks again.
      bloc.add(const EventGamesRequested('e-1', _ids));
      await pumpEventQueue();
      expect(bloc.state, failed());

      // A retry from there: gone, then, after the event's read, failed.
      bloc.add(const EventGamesRetryRequested('e-1', _ids));
      await pumpEventQueue();
      expect(bloc.state.load, EventGamesLoad.gone);
      bloc.add(const EventGamesRequested('e-1', _ids));
      await pumpEventQueue();
      expect(bloc.state, failed());

      // The bloc never reads again by itself.
      expect(remote.poolRequests, hasLength(4));
      expect(states.last, failed());
    });

    test('a second request while one is out reads once more, with the later '
        'ids', () async {
      final reads = _Held<GamesPoolRequest, List<OfferedGame>>();
      final remote = serving(pool: reads.call);
      final bloc = build(remote);
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(const EventGamesRequested('e-1', _ids));
      await pumpEventQueue();
      bloc
        ..add(const EventGamesRequested('e-1', ['a-1']))
        ..add(const EventGamesRequested('e-2', _laterIds));
      await pumpEventQueue();

      // Never two at once.
      expect(remote.poolRequests, hasLength(1));

      reads.answer(0, one);
      await pumpEventQueue();

      // The latest request's event and ids.
      expect(remote.poolRequests, [
        _poolRead('e-1', _ids),
        _poolRead('e-2', _laterIds),
      ]);

      reads.answer(1, two);
      await pumpEventQueue();

      expect(remote.poolRequests, hasLength(2));
      expect(states, [
        _loading,
        loaded(one),
        EventGamesState(load: EventGamesLoad.loading, games: one),
        loaded(two),
      ]);
    });

    test('the failure stays while the next read runs, and a read that '
        'succeeds clears it', () async {
      final reads = _Held<GamesPoolRequest, List<OfferedGame>>();
      final bloc = build(serving(pool: reads.call));
      addTearDown(bloc.close);

      bloc.add(const EventGamesRequested('e-1', _ids));
      await pumpEventQueue();
      reads.fail(0, _offline);
      await pumpEventQueue();
      final states = record(bloc);

      bloc.add(const EventGamesRequested('e-1', _ids));
      await pumpEventQueue();

      // Nobody asked for this read, so it isn't a refresh.
      expect(
        bloc.state,
        const EventGamesState(
          load: EventGamesLoad.loading,
          refreshFailed: true,
        ),
      );

      reads.answer(1, one);
      await pumpEventQueue();

      expect(states.last, loaded(one));
    });

    test(
      'a retry shows refreshing from its request until its read ends',
      () async {
        final reads = _Held<GamesPoolRequest, List<OfferedGame>>();
        Completer<bool>? asked;
        final remote = serving(pool: reads.call);
        final bloc = build(
          remote,
          confirmSession: () => asked?.future ?? Future.value(true),
        );
        addTearDown(bloc.close);

        bloc.add(const EventGamesRequested('e-1', _ids));
        await pumpEventQueue();
        reads.answer(0, one);
        await pumpEventQueue();
        bloc.add(const EventGamesRequested('e-1', _ids));
        await pumpEventQueue();
        reads.fail(1, _offline);
        await pumpEventQueue();
        expect(bloc.state, failed(games: one));

        final session = asked = Completer();
        final states = record(bloc);

        bloc.add(const EventGamesRetryRequested('e-1', _ids));
        await pumpEventQueue();

        // At once, before the session has answered: the retry is under way.
        expect(states, [
          EventGamesState(
            load: EventGamesLoad.failed,
            games: one,
            refreshFailed: true,
            refreshing: true,
          ),
        ]);
        expect(remote.poolRequests, hasLength(2));

        session.complete(true);
        await pumpEventQueue();
        reads.answer(2, two);
        await pumpEventQueue();

        expect(states.sublist(1), [
          EventGamesState(
            load: EventGamesLoad.loading,
            games: one,
            refreshFailed: true,
            refreshing: true,
          ),
          loaded(two),
        ]);
      },
    );

    test('a retry while a read is out is under way until the read after it '
        'ends', () async {
      final reads = _Held<GamesPoolRequest, List<OfferedGame>>();
      final remote = serving(pool: reads.call);
      final bloc = build(remote);
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(const EventGamesRequested('e-1', _ids));
      await pumpEventQueue();
      bloc.add(const EventGamesRetryRequested('e-1', _ids));
      await pumpEventQueue();
      reads.answer(0, one);
      await pumpEventQueue();

      // The read that was out went before the retry, so the retry's own
      // read follows it.
      expect(remote.poolRequests, hasLength(2));

      reads.answer(1, two);
      await pumpEventQueue();

      expect(states, [
        _loading,
        const EventGamesState(load: EventGamesLoad.loading, refreshing: true),
        EventGamesState(
          load: EventGamesLoad.loaded,
          games: one,
          refreshing: true,
        ),
        EventGamesState(
          load: EventGamesLoad.loading,
          games: one,
          refreshing: true,
        ),
        loaded(two),
      ]);
    });
  });

  group('the session', () {
    for (final (name, pool)
        in <(String, List<OfferedGame> Function(GamesPoolRequest))>[
          ('games', (_) => two),
          ('a refusal', (_) => throw _forbidden),
          ('a gone', (_) => throw _gone),
        ]) {
      blocTest<EventGamesBloc, EventGamesState>(
        "$name answered after the session moved is another user's, and the "
        'read is failed, keeping the old games',
        build: () => build(
          serving(pool: pool),
          confirmSession: answering([true, false]),
        ),
        seed: () => loaded(one),
        act: (bloc) => bloc.add(const EventGamesRequested('e-1', _ids)),
        skip: 1,
        expect: () => [failed(games: one)],
        verify: (_) => expect(calls, ['session', 'pool', 'session']),
      );
    }

    blocTest<EventGamesBloc, EventGamesState>(
      'a read whose session says no is failed, with no error, keeping the '
      'old games',
      build: () => build(serving(), confirmSession: answering([false])),
      seed: () => loaded(one),
      act: (bloc) => bloc.add(const EventGamesRequested('e-1', _ids)),
      expect: () => [failed(games: one)],
      verify: (_) {
        expect(calls, ['session']);
        verifyNoWarnings();
      },
    );

    test('is asked before each send and before and after the read', () async {
      final bloc = build(serving(), confirmSession: answering([true]));
      addTearDown(bloc.close);

      bloc.add(_offer(2));
      await pumpEventQueue();

      expect(calls, [
        'session',
        'offer',
        'session',
        'offer',
        'session',
        'pool',
        'session',
      ]);
    });

    test('a session that says no before a send stops the run as failed, and '
        'sends nothing more', () async {
      final remote = serving();
      final bloc = build(remote, confirmSession: answering([true, false]));
      addTearDown(bloc.close);

      bloc.add(_offer(3));
      await pumpEventQueue();

      expect(remote.offers, hasLength(1));
      expect(
        bloc.state.outcome,
        _offerEnded(EventOfferResult.failed, offered: 1, notOffered: 2),
      );
      expect(bloc.state.sending, isNull);
      // The read after the run asks too, and is told no.
      expect(remote.poolRequests, isEmpty);
      expect(bloc.state.load, EventGamesLoad.failed);
      verifyNoWarnings();
    });

    test('a session that throws is a no, and logged', () async {
      final remote = serving();
      final bloc = build(
        remote,
        confirmSession: () async => throw StateError('no answer'),
      );
      addTearDown(bloc.close);

      bloc.add(_offer(2));
      await pumpEventQueue();

      expect(remote.offers, isEmpty);
      expect(remote.poolRequests, isEmpty);
      expect(
        bloc.state,
        failed(
          outcome: _offerEnded(
            EventOfferResult.failed,
            offered: 0,
            notOffered: 2,
          ),
        ),
      );
      // The send's, then the read's.
      verifyWarnings(2);
    });
  });

  group('an offer run', () {
    test('forty picks go one at a time and count up', () async {
      final sends = _Held<OfferGameRequest, OfferedGame>();
      final remote = serving(offered: sends.call, pool: (_) => one);
      final bloc = build(remote);
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(_offer(3));
      await pumpEventQueue();

      expect(bloc.state.sending, (done: 0, total: 3));
      for (var k = 0; k < 3; k++) {
        // Never two requests out at once.
        expect(remote.offers, hasLength(k + 1));
        expect(remote.offers[k], (
          eventId: 'e-1',
          attendeeId: 'a-1',
          collectionId: 'c-${k + 1}',
        ));
        sends.answer(k, _offeredFor(sends.requests[k]));
        await pumpEventQueue();
      }

      final ended = _offerEnded(
        EventOfferResult.done,
        offered: 3,
        notOffered: 0,
      );
      expect(states, [
        const EventGamesState(sending: (done: 0, total: 3)),
        const EventGamesState(sending: (done: 1, total: 3)),
        const EventGamesState(sending: (done: 2, total: 3)),
        const EventGamesState(sending: (done: 3, total: 3)),
        EventGamesState(outcome: ended),
        // Then the pool is read again, for the ids the offer carried.
        EventGamesState(load: EventGamesLoad.loading, outcome: ended),
        loaded(one, outcome: ended),
      ]);
      expect(remote.poolRequests, [_poolRead('e-1', _ids)]);
    });

    test('already offered counts as offered', () async {
      final remote = serving(
        offered: (request) => request.collectionId == 'c-2'
            ? throw _alreadyOffered
            : _offeredFor(request),
      );
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(_offer(3));
      await pumpEventQueue();

      expect(remote.offers, hasLength(3));
      expect(
        bloc.state.outcome,
        _offerEnded(EventOfferResult.done, offered: 3, notOffered: 0),
      );
    });

    for (final (name, error) in <(String, EventRemoteException)>[
      (
        'a game gone from the collection is skipped and the run goes on',
        _leftCollection,
      ),
      ('a pick whose id the server no longer knows is skipped', _gone),
      ('a conflict with an unexpected status code is skipped', _oddConflict),
    ]) {
      test(name, () async {
        final remote = serving(
          offered: (request) => request.collectionId == 'c-2'
              ? throw error
              : _offeredFor(request),
        );
        final bloc = build(remote);
        addTearDown(bloc.close);
        final states = record(bloc);

        bloc.add(_offer(3));
        await pumpEventQueue();

        expect(remote.offers, hasLength(3));
        expect(
          bloc.state.outcome,
          _offerEnded(EventOfferResult.partly, offered: 2, notOffered: 1),
        );
        // A skipped pick is settled, and counts as done.
        expect(states.map((state) => state.sending).whereType<Object>(), [
          (done: 0, total: 3),
          (done: 1, total: 3),
          (done: 2, total: 3),
          (done: 3, total: 3),
        ]);
        expect(remote.poolRequests, hasLength(1));
        verifyNoWarnings();
      });
    }

    test(
      'a dropped connection stops the run and says how far it got',
      () async {
        final remote = serving(
          offered: (request) => request.collectionId == 'c-4'
              ? throw _offline
              : _offeredFor(request),
        );
        final bloc = build(remote);
        addTearDown(bloc.close);
        final states = record(bloc);

        bloc.add(_offer(7));
        await pumpEventQueue();

        expect(
          bloc.state.outcome,
          _offerEnded(EventOfferResult.failed, offered: 3, notOffered: 4),
        );
        expect(remote.offers, hasLength(4));
        expect(remote.poolRequests, hasLength(1));
        // The pick that stopped it isn't counted as done.
        expect(
          states.map((state) => state.sending).whereType<Object>().last,
          (done: 3, total: 7),
        );
        expect(bloc.state.sending, isNull);
        verifyWarnings(1);
      },
    );

    test('a refusal stops the run', () async {
      final remote = serving(
        offered: (request) => request.collectionId == 'c-4'
            ? throw _refused
            : _offeredFor(request),
      );
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(_offer(7));
      await pumpEventQueue();

      expect(
        bloc.state.outcome,
        _offerEnded(EventOfferResult.refused, offered: 3, notOffered: 4),
      );
      expect(remote.offers, hasLength(4));
      expect(remote.poolRequests, hasLength(1));
      verifyNoWarnings();
    });

    test('every pick refused by rule ends none', () async {
      // Each answer skips its pick, and none stops the run.
      final remote = serving(
        offered: (request) =>
            throw request.collectionId == 'c-2' ? _gone : _leftCollection,
      );
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(_offer(3));
      await pumpEventQueue();

      expect(remote.offers, hasLength(3));
      expect(
        bloc.state.outcome,
        _offerEnded(EventOfferResult.none, offered: 0, notOffered: 3),
      );
      expect(remote.poolRequests, hasLength(1));
    });

    test('offered and not offered always add up to the picks', () async {
      final runs = <(String, EventRemoteException?)>[
        ('c-9', null),
        ('c-2', _alreadyOffered),
        ('c-2', _leftCollection),
        ('c-1', _gone),
        ('c-3', _oddConflict),
        ('c-1', _refused),
        ('c-3', _refused),
        ('c-1', _offline),
        ('c-5', _offline),
      ];
      for (final (failing, error) in runs) {
        final remote = serving(
          offered: (request) => request.collectionId == failing && error != null
              ? throw error
              : _offeredFor(request),
        );
        final bloc = build(remote)..add(_offer(5));
        await pumpEventQueue();

        final outcome = bloc.state.outcome! as EventOfferOutcome;
        expect(
          outcome.offered + outcome.notOffered,
          5,
          reason: '$failing $error',
        );
        await bloc.close();
      }
    });

    test('an offer with no picks is ignored', () async {
      final remote = serving();
      final bloc = build(remote);
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(const EventGamesOffered('e-1', 'a-1', [], attendeeIds: _ids));
      await pumpEventQueue();

      expect(states, isEmpty);
      expect(remote.offers, isEmpty);
      expect(remote.poolRequests, isEmpty);
    });

    test('an offer while one is out is ignored', () async {
      final sends = _Held<OfferGameRequest, OfferedGame>();
      final remote = serving(offered: sends.call);
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(_offer(1));
      await pumpEventQueue();
      bloc.add(_offer(3));
      await pumpEventQueue();

      expect(remote.offers, hasLength(1));
      expect(bloc.state.sending, (done: 0, total: 1));

      sends.answer(0, _offeredFor(sends.requests[0]));
      await pumpEventQueue();

      expect(remote.offers, hasLength(1));
      expect(
        bloc.state.outcome,
        _offerEnded(EventOfferResult.done, offered: 1, notOffered: 0),
      );
    });

    test('a read asked for during a run goes ahead', () async {
      final sends = _Held<OfferGameRequest, OfferedGame>();
      final remote = serving(offered: sends.call, pool: (_) => one);
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(_offer(2));
      await pumpEventQueue();
      bloc.add(const EventGamesRequested('e-1', _ids));
      await pumpEventQueue();

      // The read doesn't wait for the run, and the run goes on.
      expect(remote.poolRequests, hasLength(1));
      expect(
        bloc.state,
        EventGamesState(
          load: EventGamesLoad.loaded,
          games: one,
          sending: const (done: 0, total: 2),
        ),
      );

      sends.answer(0, _offeredFor(sends.requests[0]));
      await pumpEventQueue();
      sends.answer(1, _offeredFor(sends.requests[1]));
      await pumpEventQueue();

      // And the run's own read follows it.
      expect(remote.poolRequests, hasLength(2));
    });

    test('a run that ends while a read is out has its closing read run '
        "after that one, for the run's event and ids", () async {
      final reads = _Held<GamesPoolRequest, List<OfferedGame>>();
      final remote = serving(pool: reads.call);
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(const EventGamesRequested('e-1', _ids));
      await pumpEventQueue();
      bloc.add(
        EventGamesOffered('e-2', 'a-1', _picks(1), attendeeIds: _laterIds),
      );
      await pumpEventQueue();

      // The run has ended, and its read waits for the one that is out.
      expect(
        bloc.state.outcome,
        _offerEnded(EventOfferResult.done, offered: 1, notOffered: 0),
      );
      expect(remote.poolRequests, [_poolRead('e-1', _ids)]);

      reads.answer(0, one);
      await pumpEventQueue();

      expect(remote.poolRequests, [
        _poolRead('e-1', _ids),
        _poolRead('e-2', _laterIds),
      ]);

      reads.answer(1, two);
      await pumpEventQueue();

      expect(remote.poolRequests, hasLength(2));
      expect(bloc.state.games, two);
    });

    test('a run whose roster changed while it ran has its closing read for '
        'the roster asked for since', () async {
      final sends = _Held<OfferGameRequest, OfferedGame>();
      final remote = serving(offered: sends.call, pool: (_) => one);
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(_offer(1));
      await pumpEventQueue();
      // Someone joins while the send is out, and the screen reads for them.
      bloc.add(const EventGamesRequested('e-1', _laterIds));
      await pumpEventQueue();
      sends.answer(0, _offeredFor(sends.requests[0]));
      await pumpEventQueue();

      expect(remote.poolRequests, [
        _poolRead('e-1', _laterIds),
        _poolRead('e-1', _laterIds),
      ]);
    });

    test('a new write clears the last outcome when it starts', () async {
      final bloc = build(serving(offered: (_) => throw _refused));
      addTearDown(bloc.close);

      bloc.add(_offer(1));
      await pumpEventQueue();
      expect(
        bloc.state.outcome,
        isA<EventOfferOutcome>().having(
          (outcome) => outcome.result,
          'result',
          EventOfferResult.refused,
        ),
      );
      final states = record(bloc);

      bloc.add(_offer(2));
      await pumpEventQueue();

      expect(states.first.outcome, isNull);
      expect(states.first.sending, (done: 0, total: 2));
    });
  });

  group('taking back', () {
    test('done, and reads the pool', () async {
      final takeBacks = _Held<TakeBackGameRequest, void>();
      final remote = serving(takenBack: takeBacks.call, pool: (_) => one);
      final bloc = build(remote);
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(_takeBack(_game(2)));
      await pumpEventQueue();

      expect(bloc.state.takingBack, 'g-2');
      expect(bloc.state.busy, isTrue);
      expect(remote.takeBacks, [
        (eventId: 'e-1', attendeeId: 'a-1', offeredGameId: 'g-2'),
      ]);

      takeBacks.answer(0, null);
      await pumpEventQueue();

      final ended = _takeBackEnded(EventTakeBackResult.done, _game(2));
      expect(states, [
        const EventGamesState(takingBack: 'g-2'),
        EventGamesState(outcome: ended),
        EventGamesState(load: EventGamesLoad.loading, outcome: ended),
        loaded(one, outcome: ended),
      ]);
      expect(remote.poolRequests, [_poolRead('e-1', _ids)]);
    });

    test('a take-back whose roster changed while it was out reads for the '
        'roster asked for since', () async {
      final takeBacks = _Held<TakeBackGameRequest, void>();
      final remote = serving(takenBack: takeBacks.call, pool: (_) => one);
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(_takeBack(_game(2)));
      await pumpEventQueue();
      bloc.add(const EventGamesRequested('e-1', _laterIds));
      await pumpEventQueue();
      takeBacks.answer(0, null);
      await pumpEventQueue();

      expect(remote.poolRequests, [
        _poolRead('e-1', _laterIds),
        _poolRead('e-1', _laterIds),
      ]);
    });

    for (final (name, error, result)
        in <(String, EventRemoteException, EventTakeBackResult)>[
          ('not found is done', _gone, EventTakeBackResult.done),
          (
            'a 409, the game still supplying a nomination, is stillSupplies',
            _stillSupplies,
            EventTakeBackResult.stillSupplies,
          ),
          ('refused', _refused, EventTakeBackResult.refused),
        ]) {
      test('$name, with the title, and reads the pool', () async {
        final remote = serving(takenBack: (_) => throw error);
        final bloc = build(remote);
        addTearDown(bloc.close);

        bloc.add(_takeBack(_game(2)));
        await pumpEventQueue();

        expect(bloc.state.outcome, _takeBackEnded(result, _game(2)));
        expect(bloc.state.takingBack, isNull);
        expect(remote.poolRequests, hasLength(1));
        verifyNoWarnings();
      });
    }

    /// A bloc whose pool has read [games], with reads held by [reads] from
    /// the second on, and take-backs by [takeBacks].
    Future<EventGamesBloc> holding(
      List<OfferedGame> games, {
      required _Held<GamesPoolRequest, List<OfferedGame>> reads,
      FutureOr<void> Function(TakeBackGameRequest request)? takenBack,
    }) async {
      final bloc = build(serving(pool: reads.call, takenBack: takenBack));
      addTearDown(bloc.close);
      bloc.add(const EventGamesRequested('e-1', _ids));
      await pumpEventQueue();
      reads.answer(0, games);
      await pumpEventQueue();
      expect(bloc.state, loaded(games));
      return bloc;
    }

    for (final (name, EventRemoteException? error) in [
      ('2xx', null),
      ('404', _gone),
    ]) {
      test('done by a $name drops the game in the state that carries the '
          'outcome, and the read after it still goes', () async {
        final reads = _Held<GamesPoolRequest, List<OfferedGame>>();
        final bloc = await holding(
          two,
          reads: reads,
          takenBack: (_) {
            if (error != null) throw error;
          },
        );
        final states = record(bloc);

        bloc.add(_takeBack(_game(2)));
        await pumpEventQueue();

        final ended = _takeBackEnded(EventTakeBackResult.done, _game(2));
        expect(states.take(2), [
          loaded(two).copyWith(takingBack: () => 'g-2'),
          loaded(one, outcome: ended),
        ]);
        expect(reads.requests, hasLength(2));

        reads.answer(1, one);
        await pumpEventQueue();

        expect(bloc.state, loaded(one, outcome: ended));
      });
    }

    for (final (name, error) in [
      ('stillSupplies', _stillSupplies),
      ('refused', _refused),
      ('failed', _offline),
    ]) {
      test('$name keeps the game', () async {
        final reads = _Held<GamesPoolRequest, List<OfferedGame>>();
        final bloc = await holding(
          two,
          reads: reads,
          takenBack: (_) => throw error,
        );

        bloc.add(_takeBack(_game(2)));
        await pumpEventQueue();

        expect(
          bloc.state.outcome,
          isA<EventTakeBackOutcome>().having(
            (outcome) => outcome.result,
            'result',
            isNot(EventTakeBackResult.done),
          ),
        );
        expect(bloc.state.games, two);
      });
    }

    test('a read out as a take-back ends done leaves the game out of its '
        'answer, and the read after it does not', () async {
      final reads = _Held<GamesPoolRequest, List<OfferedGame>>();
      final takeBacks = _Held<TakeBackGameRequest, void>();
      final bloc = await holding(two, reads: reads, takenBack: takeBacks.call);

      // A read goes out, then the take-back, which ends before the read
      // answers.
      bloc.add(const EventGamesRequested('e-1', _ids));
      await pumpEventQueue();
      bloc.add(_takeBack(_game(2)));
      await pumpEventQueue();
      takeBacks.answer(0, null);
      await pumpEventQueue();
      expect(bloc.state.games, one);

      // That read went out before the take-back ended, so its answer can
      // still hold the game.
      reads.answer(1, two);
      await pumpEventQueue();
      expect(bloc.state.games, one);
      expect(bloc.state.load, EventGamesLoad.loading);

      // The take-back's own read follows it, and is the server's word.
      expect(reads.requests, hasLength(3));
      reads.answer(2, two);
      await pumpEventQueue();
      expect(bloc.state.games, two);
    });

    test('failed does not read the pool', () async {
      final remote = serving(takenBack: (_) => throw _offline);
      final bloc = build(remote);
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(_takeBack(_game(2)));
      await pumpEventQueue();

      expect(states, [
        const EventGamesState(takingBack: 'g-2'),
        EventGamesState(
          outcome: _takeBackEnded(EventTakeBackResult.failed, _game(2)),
        ),
      ]);
      expect(remote.poolRequests, isEmpty);
      verifyWarnings(1);
    });

    test('a session that says no sends nothing, and is failed', () async {
      final remote = serving();
      final bloc = build(remote, confirmSession: answering([false]));
      addTearDown(bloc.close);

      bloc.add(_takeBack(_game(2)));
      await pumpEventQueue();

      expect(remote.takeBacks, isEmpty);
      expect(remote.poolRequests, isEmpty);
      expect(
        bloc.state.outcome,
        _takeBackEnded(EventTakeBackResult.failed, _game(2)),
      );
    });

    test('is ignored while an offer run is out', () async {
      final sends = _Held<OfferGameRequest, OfferedGame>();
      final remote = serving(offered: sends.call);
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(_offer(1));
      await pumpEventQueue();
      bloc.add(_takeBack(_game(2)));
      await pumpEventQueue();

      expect(remote.takeBacks, isEmpty);
      expect(bloc.state.takingBack, isNull);
    });

    test('is ignored while another is out, and so is an offer', () async {
      final takeBacks = _Held<TakeBackGameRequest, void>();
      final remote = serving(takenBack: takeBacks.call);
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(_takeBack(_game(2)));
      await pumpEventQueue();
      bloc
        ..add(_takeBack(_game(3)))
        ..add(_offer(1));
      await pumpEventQueue();

      expect(remote.takeBacks, hasLength(1));
      expect(remote.offers, isEmpty);
      expect(bloc.state, const EventGamesState(takingBack: 'g-2'));
    });
  });

  group('a dropped write', () {
    for (final (write, title) in <(EventGamesWrite, String?)>[
      (EventGamesWrite.offer, null),
      (EventGamesWrite.takeBack, 'Game 2'),
    ]) {
      blocTest<EventGamesBloc, EventGamesState>(
        'a dropped write sets its outcome and sends nothing (${write.name})',
        build: () => build(serving()),
        act: (bloc) => bloc.add(EventGamesWriteDropped(write, title: title)),
        expect: () => [
          EventGamesState(
            outcome: switch (write) {
              EventGamesWrite.offer => const EventOfferOutcome(
                result: EventOfferResult.dropped,
              ),
              EventGamesWrite.takeBack => EventTakeBackOutcome(
                result: EventTakeBackResult.dropped,
                title: title,
              ),
            },
          ),
        ],
        verify: (_) => expect(calls, isEmpty),
      );
    }

    test('each dropped offer is an outcome of its own', () async {
      final bloc = build(serving());
      addTearDown(bloc.close);
      bloc.add(const EventGamesWriteDropped(EventGamesWrite.offer));
      await pumpEventQueue();
      final first = bloc.state.outcome;
      bloc.add(const EventGamesWriteDropped(EventGamesWrite.offer));
      await pumpEventQueue();

      // The footer keys its banner on the instance (ObjectKey), so an
      // identical one would leave the banner as it was, unheard.
      expect(bloc.state.outcome, first);
      expect(identical(bloc.state.outcome, first), isFalse);
    });

    blocTest<EventGamesBloc, EventGamesState>(
      'the same drop twice is two outcomes, cleared between',
      build: () => build(serving()),
      act: (bloc) => bloc
        ..add(
          const EventGamesWriteDropped(EventGamesWrite.takeBack, title: 'A'),
        )
        ..add(
          const EventGamesWriteDropped(EventGamesWrite.takeBack, title: 'A'),
        ),
      expect: () => const [
        EventGamesState(
          outcome: EventTakeBackOutcome(
            result: EventTakeBackResult.dropped,
            title: 'A',
          ),
        ),
        EventGamesState(),
        EventGamesState(
          outcome: EventTakeBackOutcome(
            result: EventTakeBackResult.dropped,
            title: 'A',
          ),
        ),
      ],
      verify: (_) => expect(calls, isEmpty),
    );

    test('is ignored while a run is out', () async {
      final sends = _Held<OfferGameRequest, OfferedGame>();
      final bloc = build(serving(offered: sends.call));
      addTearDown(bloc.close);

      bloc.add(_offer(2));
      await pumpEventQueue();
      final states = record(bloc);
      bloc.add(const EventGamesWriteDropped(EventGamesWrite.offer));
      await pumpEventQueue();

      expect(states, isEmpty);
      expect(bloc.state.outcome, isNull);
    });
  });

  group('the outcome', () {
    blocTest<EventGamesBloc, EventGamesState>(
      'dismissed clears the outcome and nothing else',
      build: () => build(serving()),
      seed: () => loaded(
        one,
        outcome: _takeBackEnded(EventTakeBackResult.refused, _game(1)),
      ),
      act: (bloc) => bloc.add(const EventGamesOutcomeDismissed()),
      expect: () => [loaded(one)],
    );

    blocTest<EventGamesBloc, EventGamesState>(
      'dismissed with none emits nothing',
      build: () => build(serving()),
      seed: () => loaded(one),
      act: (bloc) => bloc.add(const EventGamesOutcomeDismissed()),
      expect: () => <EventGamesState>[],
    );
  });

  group('closing', () {
    test('nothing is emitted after close with a send still out', () async {
      final sends = _Held<OfferGameRequest, OfferedGame>();
      final remote = serving(offered: sends.call);
      final bloc = build(remote);
      final states = record(bloc);
      final errors = <Object>[];
      final watching = bloc.stream.listen(null, onError: errors.add);
      addTearDown(watching.cancel);

      bloc.add(_offer(2));
      await pumpEventQueue();
      // The screen leaves while the first send is out.
      await bloc.close();
      sends.answer(0, _offeredFor(sends.requests[0]));
      await pumpEventQueue();

      expect(states, [const EventGamesState(sending: (done: 0, total: 2))]);
      expect(errors, isEmpty);
      // The run stops sending, and reads nothing.
      expect(remote.offers, hasLength(1));
      expect(remote.poolRequests, isEmpty);
    });

    test('a take-back answered after close emits nothing', () async {
      final takeBacks = _Held<TakeBackGameRequest, void>();
      final remote = serving(takenBack: takeBacks.call);
      final bloc = build(remote);
      final states = record(bloc);

      bloc.add(_takeBack(_game(2)));
      await pumpEventQueue();
      await bloc.close();
      takeBacks.answer(0, null);
      await pumpEventQueue();

      expect(states, [const EventGamesState(takingBack: 'g-2')]);
      expect(remote.poolRequests, isEmpty);
    });

    test('a read answered after close emits nothing', () async {
      final reads = _Held<GamesPoolRequest, List<OfferedGame>>();
      final bloc = build(serving(pool: reads.call));
      final states = record(bloc);

      bloc.add(const EventGamesRequested('e-1', _ids));
      await pumpEventQueue();
      await bloc.close();
      reads.answer(0, one);
      await pumpEventQueue();

      expect(states, [_loading]);
    });
  });
}
