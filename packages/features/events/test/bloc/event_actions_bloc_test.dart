import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../support/fake_event_remote.dart';

class _MockEventRepository extends Mock implements EventRepository {}

class _MockBgeLogger extends Mock implements BgeLogger {}

const _gone = EventRemoteNotFoundException('gone', statusCode: 404);
const _refused = EventWriteRefusedException('no', statusCode: 403);
const _offline = EventRemoteTransientException('offline');
const _rejected = EventRemotePermanentException('bad', statusCode: 400);

/// The delete on the event detail screen (#501): sent online, never queued,
/// reported as done, gone, refused or failed, and written to the cache after
/// the outcome is out.
void main() {
  late _MockEventRepository repository;
  late _MockBgeLogger logger;

  /// What the bloc called, in order, where a test records it.
  late List<String> calls;

  setUp(() {
    repository = _MockEventRepository();
    logger = _MockBgeLogger();
    calls = [];
    when(() => repository.removeDeletedEvent(any())).thenAnswer((_) async {
      calls.add('remove');
      return true;
    });
  });

  /// A server whose deletes answer as [deleted] does, recording each.
  FakeEventRemote serving(FutureOr<void> Function(String id) deleted) =>
      FakeEventRemote.detail(
        (_) => throw UnimplementedError('the actions read nothing'),
        deleted: (id) {
          calls.add('delete');
          return deleted(id);
        },
      );

  EventActionsBloc build(
    FakeEventRemote remote, {
    Future<bool> Function()? confirmSession,
  }) => EventActionsBloc(
    repository: repository,
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
  List<EventActionsState> record(EventActionsBloc bloc) {
    final states = <EventActionsState>[];
    final subscription = bloc.stream.listen(states.add);
    addTearDown(subscription.cancel);
    return states;
  }

  const busy = EventActionsState(busy: true);

  EventActionsState settled(EventActionResult result, {Object? error}) =>
      EventActionsState(
        outcome: EventActionOutcome(
          action: EventAction.delete,
          result: result,
          error: error,
        ),
      );

  void verifyNoWrite() {
    verifyNever(() => repository.removeDeletedEvent(any()));
    verifyNever(
      () => repository.forgetEvent(any(), lastWrite: any(named: 'lastWrite')),
    );
    verifyNever(() => repository.lastWrite(any()));
  }

  void verifyWarnings(int count) => verify(
    () => logger.warn(
      any(),
      error: any(named: 'error'),
      stackTrace: any(named: 'stackTrace'),
    ),
  ).called(count);

  test('starts idle, with no outcome', () {
    final bloc = build(serving((_) {}));
    addTearDown(bloc.close);

    expect(bloc.state, const EventActionsState());
  });

  group('the answers', () {
    test('a 200 is done, then removes the event', () async {
      final removal = Completer<bool>();
      late EventActionsBloc bloc;
      final stateAtRemoval = <EventActionsState>[];
      when(() => repository.removeDeletedEvent(any())).thenAnswer((_) {
        stateAtRemoval.add(bloc.state);
        return removal.future;
      });
      final remote = serving((_) {});
      bloc = build(remote);
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(const EventDeleteRequested('e-1'));
      await pumpEventQueue();

      expect(remote.deleteRequests, ['e-1']);
      // Done is out while the removal still runs, so the screen can leave
      // before the removal's null reaches the detail's watch.
      expect(states, [busy, settled(EventActionResult.done)]);
      expect(stateAtRemoval, [settled(EventActionResult.done)]);
      verify(() => repository.removeDeletedEvent('e-1')).called(1);
      expect(bloc.state.outcome!.rereads, isFalse);

      removal.complete(true);
      await pumpEventQueue();

      expect(states, hasLength(2));
    });

    blocTest<EventActionsBloc, EventActionsState>(
      'a 404 is gone, then removes the event as a 200 does',
      // The server has no live event with the id for anyone, and nothing
      // restores one, so this user's forget and its mark would undersell it.
      build: () => build(serving((_) => throw _gone)),
      act: (bloc) => bloc.add(const EventDeleteRequested('e-1')),
      expect: () => [busy, settled(EventActionResult.gone, error: _gone)],
      verify: (bloc) {
        expect(calls, ['delete', 'remove']);
        verify(() => repository.removeDeletedEvent('e-1')).called(1);
        verifyNever(
          () =>
              repository.forgetEvent(any(), lastWrite: any(named: 'lastWrite')),
        );
        expect(bloc.state.outcome!.rereads, isFalse);
      },
    );

    blocTest<EventActionsBloc, EventActionsState>(
      'a 403 is refused, and rereads',
      build: () => build(serving((_) => throw _refused)),
      act: (bloc) => bloc.add(const EventDeleteRequested('e-1')),
      expect: () => [busy, settled(EventActionResult.refused, error: _refused)],
      verify: (bloc) {
        expect(bloc.state.outcome!.rereads, isTrue);
        verifyNoWrite();
      },
    );

    blocTest<EventActionsBloc, EventActionsState>(
      "a transient failure fails, and doesn't reread",
      build: () => build(serving((_) => throw _offline)),
      act: (bloc) => bloc.add(const EventDeleteRequested('e-1')),
      expect: () => [busy, settled(EventActionResult.failed, error: _offline)],
      verify: (bloc) {
        expect(bloc.state.outcome!.rereads, isFalse);
        verifyNoWrite();
        verifyWarnings(1);
      },
    );

    blocTest<EventActionsBloc, EventActionsState>(
      'a permanent failure fails, and rereads',
      build: () => build(serving((_) => throw _rejected)),
      act: (bloc) => bloc.add(const EventDeleteRequested('e-1')),
      expect: () => [busy, settled(EventActionResult.failed, error: _rejected)],
      verify: (bloc) {
        // It may have been a delete this device could not read.
        expect(bloc.state.outcome!.rereads, isTrue);
        verifyNoWrite();
        verifyWarnings(1);
      },
    );
  });

  test('a second request while busy sends nothing', () async {
    final reply = Completer<void>();
    final remote = serving((_) => reply.future);
    final bloc = build(remote);
    addTearDown(bloc.close);
    final states = record(bloc);

    bloc.add(const EventDeleteRequested('e-1'));
    await pumpEventQueue();
    // A double tap on the dialog, or another event's id: one request at a
    // time, whichever it names.
    bloc
      ..add(const EventDeleteRequested('e-1'))
      ..add(const EventDeleteRequested('e-2'));
    await pumpEventQueue();

    expect(remote.deleteRequests, ['e-1']);

    reply.complete();
    await pumpEventQueue();

    expect(remote.deleteRequests, ['e-1']);
    expect(states, [busy, settled(EventActionResult.done)]);
    verify(() => repository.removeDeletedEvent('e-1')).called(1);
  });

  group('the session', () {
    blocTest<EventActionsBloc, EventActionsState>(
      'the session is asked before sending, and again before writing',
      build: () =>
          build(serving((_) {}), confirmSession: answering([true, true])),
      act: (bloc) => bloc.add(const EventDeleteRequested('e-1')),
      expect: () => [busy, settled(EventActionResult.done)],
      verify: (_) => expect(calls, ['session', 'delete', 'session', 'remove']),
    );

    for (final (name, guard) in <(String, Future<bool> Function())>[
      ('says no', () async => false),
      ('throws', () async => throw StateError('no answer')),
    ]) {
      blocTest<EventActionsBloc, EventActionsState>(
        'a session that $name before sending fails, sends nothing and '
        "doesn't reread",
        build: () => build(serving((_) {}), confirmSession: guard),
        act: (bloc) => bloc.add(const EventDeleteRequested('e-1')),
        // No error: nothing reached the server, and a read would ask the
        // same session.
        expect: () => [busy, settled(EventActionResult.failed)],
        verify: (bloc) {
          expect(calls, isEmpty);
          expect(bloc.state.outcome!.rereads, isFalse);
          verifyNoWrite();
        },
      );
    }

    test('a guard that throws is logged', () async {
      final bloc = build(
        serving((_) {}),
        confirmSession: () async => throw StateError('no answer'),
      );
      addTearDown(bloc.close);

      bloc.add(const EventDeleteRequested('e-1'));
      await pumpEventQueue();

      verifyWarnings(1);
    });

    for (final (answer, deleted, result, error)
        in <
          (String, FutureOr<void> Function(String), EventActionResult, Object?)
        >[
          ('200', (_) {}, EventActionResult.done, null),
          ('404', (_) => throw _gone, EventActionResult.gone, _gone),
        ]) {
      blocTest<EventActionsBloc, EventActionsState>(
        'a session that moved while the request was out writes nothing '
        '($answer)',
        build: () =>
            build(serving(deleted), confirmSession: answering([true, false])),
        act: (bloc) => bloc.add(const EventDeleteRequested('e-1')),
        // The server answered, and the outcome says what it answered. Only
        // the cache, now another user's, is left alone.
        expect: () => [busy, settled(result, error: error)],
        verify: (_) => verifyNoWrite(),
      );
    }
  });

  blocTest<EventActionsBloc, EventActionsState>(
    'a removal that throws is still done',
    setUp: () =>
        when(() => repository.removeDeletedEvent(any()))
            .thenThrow(StateError('database closed')),
    build: () => build(serving((_) {})),
    act: (bloc) => bloc.add(const EventDeleteRequested('e-1')),
    expect: () => [busy, settled(EventActionResult.done)],
    verify: (_) => verifyWarnings(1),
  );

  blocTest<EventActionsBloc, EventActionsState>(
    'a removal that declines is still done, and logged',
    // Nothing cached under the id, or the sync queue owns it.
    setUp: () =>
        when(() => repository.removeDeletedEvent(any()))
            .thenAnswer((_) async => false),
    build: () => build(serving((_) {})),
    act: (bloc) => bloc.add(const EventDeleteRequested('e-1')),
    expect: () => [busy, settled(EventActionResult.done)],
    verify: (_) => verify(() => logger.info(any())).called(1),
  );

  group('closing', () {
    // Made in each test's own setUp, inside the zone bloc_test runs the bloc
    // in: an error can't cross from another error zone to the request.
    late Completer<void> reply;

    blocTest<EventActionsBloc, EventActionsState>(
      'a bloc closed while the request is out emits nothing more, and still '
      'removes the event',
      setUp: () => reply = Completer<void>(),
      build: () => build(serving((_) => reply.future)),
      act: (bloc) async {
        bloc.add(const EventDeleteRequested('e-1'));
        await pumpEventQueue();

        // The screen leaves while the DELETE is out.
        await bloc.close();
        reply.complete();
        await pumpEventQueue();
      },
      expect: () => [busy],
      verify: (_) =>
          verify(() => repository.removeDeletedEvent('e-1')).called(1),
    );

    blocTest<EventActionsBloc, EventActionsState>(
      'a bloc closed while the request is out still removes a gone event',
      setUp: () => reply = Completer<void>(),
      build: () => build(serving((_) => reply.future)),
      act: (bloc) async {
        bloc.add(const EventDeleteRequested('e-1'));
        await pumpEventQueue();

        await bloc.close();
        reply.completeError(_gone);
        await pumpEventQueue();
      },
      expect: () => [busy],
      verify: (_) =>
          verify(() => repository.removeDeletedEvent('e-1')).called(1),
    );

    test('a bloc that starts closing as the answer is settled emits nothing '
        'more', () async {
      // Close starts while the second session ask is out, so the outcome is
      // ready before bloc's own close has cancelled the handler, which it
      // does only after the event stream has closed. The bloc's own check is
      // what keeps the outcome off a closing stream.
      late EventActionsBloc bloc;
      Future<void>? closing;
      var asked = 0;
      bloc = build(
        serving((_) {}),
        confirmSession: () async {
          if (++asked == 2) closing = bloc.close();
          return true;
        },
      );
      final states = record(bloc);

      bloc.add(const EventDeleteRequested('e-1'));
      await pumpEventQueue();
      await closing;

      expect(states, [busy]);
      verify(() => repository.removeDeletedEvent('e-1')).called(1);
    });
  });

  group('dismissing', () {
    blocTest<EventActionsBloc, EventActionsState>(
      'dismissing clears the outcome',
      build: () => build(serving((_) {})),
      seed: () => settled(EventActionResult.refused, error: _refused),
      act: (bloc) => bloc.add(const EventActionOutcomeDismissed()),
      expect: () => [const EventActionsState()],
    );

    blocTest<EventActionsBloc, EventActionsState>(
      'dismissing does nothing while there is no outcome',
      build: () => build(serving((_) {})),
      act: (bloc) => bloc.add(const EventActionOutcomeDismissed()),
      expect: () => <EventActionsState>[],
    );
  });
}
