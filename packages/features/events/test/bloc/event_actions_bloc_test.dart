import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:di/di.dart' show LocalClockService;
import 'package:drift_storage/drift_storage.dart';
import 'package:drift_storage/drift_storage_native.dart'
    show inMemoryServerDatabase;
import 'package:events/events.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../support/event_list_items.dart';
import '../support/fake_event_remote.dart';

class _MockEventRepository extends Mock implements EventRepository {}

class _MockBgeLogger extends Mock implements BgeLogger {}

/// The real cache, telling [onLanded] each time a date write has landed, so
/// a test can see what the bloc had emitted by then.
class _LandingCache extends EventRepositoryImpl {
  _LandingCache(
    super.db, {
    required super.userId,
    required super.syncQueue,
    required super.clock,
  });

  void Function()? onLanded;

  @override
  Future<bool> cacheOccurrence(EventOccurrence occurrence) async {
    try {
      return await super.cacheOccurrence(occurrence);
    } finally {
      onLanded?.call();
    }
  }

  @override
  Future<bool> removeCachedOccurrence({
    required String eventId,
    required String occurrenceId,
  }) async {
    try {
      return await super.removeCachedOccurrence(
        eventId: eventId,
        occurrenceId: occurrenceId,
      );
    } finally {
      onLanded?.call();
    }
  }
}

const _gone = EventRemoteNotFoundException('gone', statusCode: 404);
const _refused = EventWriteRefusedException('no', statusCode: 403);
const _offline = EventRemoteTransientException('offline');
const _rejected = EventRemotePermanentException('bad', statusCode: 400);
const _conflict = EventWriteConflictException('moved', statusCode: 400);

/// The actions on the event detail screen: the delete (#501) and the date
/// writes (#506). Each is sent online, never queued, and reported as how it
/// ended. The delete writes the cache after its outcome is out, and a date
/// write before.
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
      'the session is asked before sending, and not before writing',
      build: () => build(serving((_) {}), confirmSession: answering([true])),
      act: (bloc) => bloc.add(const EventDeleteRequested('e-1')),
      expect: () => [busy, settled(EventActionResult.done)],
      verify: (_) => expect(calls, ['session', 'delete', 'remove']),
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
        'a session that moved while the request was out still removes the '
        'event ($answer)',
        // Were it asked again, the guard would say no.
        build: () =>
            build(serving(deleted), confirmSession: answering([true, false])),
        act: (bloc) => bloc.add(const EventDeleteRequested('e-1')),
        // The server deleted the event for everyone, so the removal holds
        // whoever is signed in now.
        expect: () => [busy, settled(result, error: error)],
        verify: (_) {
          expect(calls, ['session', 'delete', 'remove']);
          verify(() => repository.removeDeletedEvent('e-1')).called(1);
        },
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
      // Close starts as the server answers, so the outcome is ready before
      // bloc's own close has cancelled the handler, which it does only after
      // the event stream has closed. The bloc's own check is what keeps the
      // outcome off a closing stream.
      late EventActionsBloc bloc;
      Future<void>? closing;
      bloc = build(
        serving((_) {
          closing = bloc.close();
        }),
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

  group('date actions (#506)', () {
    // The real cache, as the detail bloc's tests use it: a date write is
    // judged by what the cache holds after it, and by when it held it.
    late ServerDatabase db;
    late _LandingCache cached;

    final start = DateTime.utc(2026, 11, 7, 18);
    final answeredAt = DateTime.utc(2026, 10, 28, 9);

    /// Date `d-1` of `e-1`, proposed.
    final proposedDate = confirmed(
      'd-1',
      start,
    ).copyWith(eventId: 'e-1', status: OccurrenceStatus.proposed);

    /// `d-1` as the server holds it once confirmed.
    final confirmedDate = proposedDate.copyWith(
      status: OccurrenceStatus.confirmed,
      confirmedAt: answeredAt,
      updatedAt: answeredAt,
    );

    /// `d-1` as the server holds it once the confirmed date is cancelled.
    final cancelledDate = confirmedDate.copyWith(
      status: OccurrenceStatus.cancelled,
      cancelledAt: answeredAt,
      cancelReason: 'Rained off',
    );

    /// Caches `e-1` as a detail read would, with [date] its only date.
    Future<void> holding(EventOccurrence date) => cached.cacheEvent(
      EventSnapshot(
        event: item('e-1').event,
        occurrences: [date],
        attendees: const [],
      ),
      source: EventAccessSource.read,
    );

    setUp(() async {
      db = inMemoryServerDatabase();
      cached = _LandingCache(
        db,
        userId: 'user-me',
        syncQueue: SyncQueueRepositoryImpl(
          db,
          const LocalClockService(),
          userId: 'user-me',
        ),
        clock: const LocalClockService(),
      );
      await holding(proposedDate);
    });

    tearDown(() => db.close());

    /// The dates the cache holds for `e-1`.
    Future<List<EventOccurrence>> cachedDates() async =>
        (await cached.getEvent('e-1'))!.occurrences;

    /// A server whose date writes answer as [answer] does, recording each
    /// call.
    FakeEventRemote dating(
      FutureOr<EventOccurrence?> Function(EventDateRequest request) answer,
    ) => FakeEventRemote.detail(
      (_) => throw UnimplementedError('the actions read nothing'),
      dateWritten: (request) {
        calls.add(request.call);
        return answer(request);
      },
    );

    EventActionsBloc over(
      FakeEventRemote remote, {
      Future<bool> Function()? confirmSession,
    }) => EventActionsBloc(
      repository: cached,
      remote: remote,
      confirmSession: confirmSession,
      logger: logger,
    );

    /// [bloc]'s next outcome. Listens at once, so call it before the
    /// outcome can be emitted.
    Future<EventActionOutcome> answered(EventActionsBloc bloc) async =>
        (await bloc.stream.firstWhere((s) => s.outcome != null)).outcome!;

    EventActionsState ended(
      EventAction action,
      EventActionResult result, {
      Object? error,
    }) => EventActionsState(
      outcome: EventActionOutcome(action: action, result: result, error: error),
    );

    /// What a [call] to `e-1` sends, naming `d-1` unless it says otherwise.
    EventDateRequest sent(
      String call, {
      String? occurrenceId = 'd-1',
      EventOccurrenceDraft? draft,
      int? sortOrder,
      OccurrenceUpdate? update,
      String? reason,
    }) => (
      call: call,
      eventId: 'e-1',
      occurrenceId: occurrenceId,
      draft: draft,
      sortOrder: sortOrder,
      update: update,
      reason: reason,
    );

    const confirm = EventDateConfirmRequested('e-1', 'd-1');

    test(
      'a confirm writes the returned date, then says done and re-reads',
      () async {
        final remote = dating((_) => confirmedDate);
        final bloc = over(remote);
        addTearDown(bloc.close);
        final states = record(bloc);
        final stateAtWrite = <EventActionsState>[];
        cached.onLanded = () => stateAtWrite.add(bloc.state);

        bloc.add(confirm);
        final outcome = await answered(bloc);

        expect(remote.dateRequests, [sent('confirm')]);
        // Written while the request was still out: the outcome starts the
        // read, and a write after it could land over the read's newer copy.
        expect(stateAtWrite, [busy]);
        expect(await cachedDates(), [confirmedDate]);
        expect(states, [
          busy,
          ended(EventAction.confirmDate, EventActionResult.done),
        ]);
        expect(outcome.rereads, isTrue);
      },
    );

    test(
      'an add sends the draft with its sortOrder and caches the new date',
      () async {
        final draft = EventOccurrenceDraft(
          label: 'Sunday',
          startDate: start.add(const Duration(days: 1)),
        );
        final added = proposedDate.copyWith(
          id: 'd-2',
          label: 'Sunday',
          startDate: draft.startDate,
          sortOrder: 1,
          createdAt: answeredAt,
          updatedAt: answeredAt,
        );
        final remote = dating((_) => added);
        final bloc = over(remote);
        addTearDown(bloc.close);

        bloc.add(EventDateAddRequested('e-1', draft, sortOrder: 1));
        final outcome = await answered(bloc);

        expect(remote.dateRequests, [
          sent('add', occurrenceId: null, draft: draft, sortOrder: 1),
        ]);
        expect(await cachedDates(), [proposedDate, added]);
        expect(
          outcome,
          const EventActionOutcome(
            action: EventAction.addDate,
            result: EventActionResult.done,
          ),
        );
        expect(outcome.rereads, isTrue);
      },
    );

    test('a remove removes the cached date', () async {
      final remote = dating((_) => null);
      final bloc = over(remote);
      addTearDown(bloc.close);

      bloc.add(const EventDateRemoveRequested('e-1', 'd-1'));
      final outcome = await answered(bloc);

      expect(remote.dateRequests, [sent('remove')]);
      expect(await cachedDates(), isEmpty);
      expect(
        outcome,
        const EventActionOutcome(
          action: EventAction.removeDate,
          result: EventActionResult.done,
        ),
      );
      expect(outcome.rereads, isTrue);
    });

    for (final (name, call, request, action, answer)
        in <(String, String, EventActionsEvent, EventAction, EventOccurrence)>[
          (
            'an edit',
            'update',
            EventDateEditRequested(
              'e-1',
              'd-1',
              OccurrenceUpdate(label: 'Saturday'),
            ),
            EventAction.editDate,
            proposedDate.copyWith(label: 'Saturday', updatedAt: answeredAt),
          ),
          (
            'a decline',
            'decline',
            const EventDateDeclineRequested('e-1', 'd-1'),
            EventAction.declineDate,
            proposedDate.copyWith(
              status: OccurrenceStatus.declined,
              declinedAt: answeredAt,
              updatedAt: answeredAt,
            ),
          ),
          (
            'a cancel',
            'cancel',
            const EventDateCancelRequested('e-1', 'd-1', reason: 'Rained off'),
            EventAction.cancelDate,
            cancelledDate,
          ),
        ]) {
      test('$name sends what it was asked, and writes the date it is '
          'answered with', () async {
        final remote = dating((_) => answer);
        final bloc = over(remote);
        addTearDown(bloc.close);

        bloc.add(request);
        final outcome = await answered(bloc);

        expect(remote.dateRequests, [
          switch (request) {
            EventDateEditRequested(:final update) => sent(call, update: update),
            EventDateCancelRequested(:final reason) => sent(
              call,
              reason: reason,
            ),
            _ => sent(call),
          },
        ]);
        expect(await cachedDates(), [answer]);
        expect(
          outcome,
          EventActionOutcome(action: action, result: EventActionResult.done),
        );
      });
    }

    for (final (name, error, result, rereads)
        in <(String, Object, EventActionResult, bool)>[
          (
            'a 400 is changed and writes nothing',
            _conflict,
            EventActionResult.changed,
            true,
          ),
          ('a 404 is gone', _gone, EventActionResult.gone, true),
          ('a 403 is refused', _refused, EventActionResult.refused, true),
          (
            'a transient failure on confirm is failed and does not re-read',
            _offline,
            EventActionResult.failed,
            false,
          ),
          (
            'a permanent failure on confirm is failed and re-reads',
            _rejected,
            EventActionResult.failed,
            true,
          ),
        ]) {
      test(name, () async {
        final bloc = over(dating((_) => throw error));
        addTearDown(bloc.close);

        bloc.add(confirm);
        final outcome = await answered(bloc);

        expect(
          outcome,
          EventActionOutcome(
            action: EventAction.confirmDate,
            result: result,
            error: error,
          ),
        );
        expect(outcome.rereads, rereads);
        // Nothing the server holds came back to write. A read brings it.
        expect(await cachedDates(), [proposedDate]);
      });
    }

    test('a transient failure on add re-reads', () async {
      // A retried add creates a second date (backend#902), so an add whose
      // answer was lost is read for before Add can be pressed again.
      final bloc = over(dating((_) => throw _offline));
      addTearDown(bloc.close);

      bloc.add(
        const EventDateAddRequested(
          'e-1',
          EventOccurrenceDraft(label: 'Sunday'),
          sortOrder: 1,
        ),
      );
      final outcome = await answered(bloc);

      expect(
        outcome,
        const EventActionOutcome(
          action: EventAction.addDate,
          result: EventActionResult.failed,
          error: _offline,
        ),
      );
      expect(outcome.rereads, isTrue);
      expect(await cachedDates(), [proposedDate]);
    });

    group('cancel then remove (#446)', () {
      const cancelThenRemove = EventDateRemoveRequested(
        'e-1',
        'd-1',
        cancelFirst: true,
        reason: 'Rained off',
      );

      setUp(() => holding(confirmedDate));

      test('cancel then remove cancels, then removes', () async {
        final remote = dating(
          (request) => request.call == 'cancel' ? cancelledDate : null,
        );
        final bloc = over(remote, confirmSession: answering([true]));
        addTearDown(bloc.close);

        bloc.add(cancelThenRemove);
        final outcome = await answered(bloc);

        expect(remote.dateRequests, [
          sent('cancel', reason: 'Rained off'),
          sent('remove'),
        ]);
        // Each request goes out with the session checked first (#432).
        expect(calls, ['session', 'cancel', 'session', 'remove']);
        expect(await cachedDates(), isEmpty);
        expect(
          outcome,
          const EventActionOutcome(
            action: EventAction.removeDate,
            result: EventActionResult.done,
          ),
        );
        expect(outcome.rereads, isTrue);
      });

      test('cancel then remove stops when the cancel answers 400', () async {
        // Cancelled elsewhere, say. The read shows it Cancelled, and a
        // Cancelled date offers a plain Remove.
        final remote = dating((_) => throw _conflict);
        final bloc = over(remote);
        addTearDown(bloc.close);

        bloc.add(cancelThenRemove);
        final outcome = await answered(bloc);

        expect(remote.dateRequests, [sent('cancel', reason: 'Rained off')]);
        expect(
          outcome,
          const EventActionOutcome(
            action: EventAction.removeDate,
            result: EventActionResult.changed,
            error: _conflict,
          ),
        );
        expect(outcome.rereads, isTrue);
        expect(await cachedDates(), [confirmedDate]);
      });

      for (final (error, result) in <(Object, EventActionResult)>[
        (_gone, EventActionResult.gone),
        (_refused, EventActionResult.refused),
        (_offline, EventActionResult.failed),
      ]) {
        test('cancel then remove stops when the cancel is ${result.name}, '
            'and says so', () async {
          final remote = dating((_) => throw error);
          final bloc = over(remote);
          addTearDown(bloc.close);

          bloc.add(cancelThenRemove);
          final outcome = await answered(bloc);

          expect(calls, ['cancel']);
          expect(
            outcome,
            EventActionOutcome(
              action: EventAction.removeDate,
              result: result,
              error: error,
            ),
          );
          expect(await cachedDates(), [confirmedDate]);
        });
      }

      for (final error in <Object>[_offline, _refused, _conflict]) {
        test('cancel then remove whose remove fails is partlyDone '
            '(${error.runtimeType})', () async {
          final remote = dating(
            (request) => request.call == 'cancel' ? cancelledDate : throw error,
          );
          final bloc = over(remote);
          addTearDown(bloc.close);

          bloc.add(cancelThenRemove);
          final outcome = await answered(bloc);

          expect(calls, ['cancel', 'remove']);
          // The cancel's answer is written, so the date shows Cancelled
          // and offers Remove again.
          expect(await cachedDates(), [cancelledDate]);
          expect(
            outcome,
            EventActionOutcome(
              action: EventAction.removeDate,
              result: EventActionResult.partlyDone,
              error: error,
            ),
          );
          expect(outcome.rereads, isTrue);
        });
      }

      test('cancel then remove whose remove finds the date gone is gone, not '
          'partlyDone', () async {
        // There is no date left to remove, so "you can remove it now"
        // would be false.
        final remote = dating(
          (request) => request.call == 'cancel' ? cancelledDate : throw _gone,
        );
        final bloc = over(remote);
        addTearDown(bloc.close);

        bloc.add(cancelThenRemove);
        final outcome = await answered(bloc);

        expect(calls, ['cancel', 'remove']);
        expect(
          outcome,
          const EventActionOutcome(
            action: EventAction.removeDate,
            result: EventActionResult.gone,
            error: _gone,
          ),
        );
        expect(outcome.rereads, isTrue);
      });

      test('cancel then remove whose session moves before the remove is '
          'partlyDone, and sends no remove', () async {
        final remote = dating((_) => cancelledDate);
        final bloc = over(remote, confirmSession: answering([true, false]));
        addTearDown(bloc.close);

        bloc.add(cancelThenRemove);
        final outcome = await answered(bloc);

        expect(calls, ['session', 'cancel', 'session']);
        expect(await cachedDates(), [cancelledDate]);
        expect(
          outcome,
          const EventActionOutcome(
            action: EventAction.removeDate,
            result: EventActionResult.partlyDone,
          ),
        );
        expect(outcome.rereads, isTrue);
      });
    });

    test(
      'the session is asked before any date write, and a no sends nothing',
      () async {
        final requests = <(EventActionsEvent, EventAction)>[
          (
            const EventDateAddRequested(
              'e-1',
              EventOccurrenceDraft(label: 'Sunday'),
              sortOrder: 1,
            ),
            EventAction.addDate,
          ),
          (
            EventDateEditRequested(
              'e-1',
              'd-1',
              OccurrenceUpdate(label: 'Saturday'),
            ),
            EventAction.editDate,
          ),
          (confirm, EventAction.confirmDate),
          (
            const EventDateDeclineRequested('e-1', 'd-1'),
            EventAction.declineDate,
          ),
          (
            const EventDateCancelRequested('e-1', 'd-1'),
            EventAction.cancelDate,
          ),
          (
            const EventDateRemoveRequested('e-1', 'd-1'),
            EventAction.removeDate,
          ),
          (
            const EventDateRemoveRequested('e-1', 'd-1', cancelFirst: true),
            EventAction.removeDate,
          ),
        ];

        for (final (request, action) in requests) {
          calls.clear();
          final remote = dating((_) => throw StateError('sent'));
          final bloc = over(remote, confirmSession: answering([false]));
          addTearDown(bloc.close);

          bloc.add(request);
          final outcome = await answered(bloc);

          expect(calls, ['session'], reason: '$request');
          // No error: nothing reached the server, and a read would ask the
          // same session.
          expect(
            outcome,
            EventActionOutcome(
              action: action,
              result: EventActionResult.failed,
            ),
            reason: '$request',
          );
          expect(outcome.rereads, isFalse, reason: '$request');
        }
        expect(await cachedDates(), [proposedDate]);
      },
    );

    test(
      'a session that moved while the request was out still writes the date',
      () async {
        // Were it asked again, the guard would say no. The date is the
        // server's, the same for everyone who can read the event.
        final bloc = over(
          dating((_) => confirmedDate),
          confirmSession: answering([true, false]),
        );
        addTearDown(bloc.close);

        bloc.add(confirm);
        final outcome = await answered(bloc);

        expect(calls, ['session', 'confirm']);
        expect(outcome.result, EventActionResult.done);
        expect(await cachedDates(), [confirmedDate]);
      },
    );

    test('a second request while one is out is dropped', () async {
      final reply = Completer<EventOccurrence>();
      final remote = dating((_) => reply.future);
      final bloc = over(remote);
      addTearDown(bloc.close);
      final states = record(bloc);

      bloc.add(confirm);
      await pumpEventQueue();
      // A double tap, another date's action, or the delete: one request at a
      // time, whatever it asks for.
      bloc
        ..add(confirm)
        ..add(const EventDateDeclineRequested('e-1', 'd-2'))
        ..add(const EventDeleteRequested('e-1'));
      await pumpEventQueue();

      final outcome = answered(bloc);
      reply.complete(confirmedDate);
      await outcome;

      expect(remote.dateRequests, [sent('confirm')]);
      expect(remote.deleteRequests, isEmpty);
      expect(states, [
        busy,
        ended(EventAction.confirmDate, EventActionResult.done),
      ]);
    });

    test('an answer that lands after close still writes the date', () async {
      final reply = Completer<EventOccurrence>();
      final landed = Completer<void>();
      cached.onLanded = landed.complete;
      final bloc = over(dating((_) => reply.future));
      final states = record(bloc);

      bloc.add(confirm);
      await pumpEventQueue();
      // The screen leaves while the request is out.
      await bloc.close();
      reply.complete(confirmedDate);
      await landed.future;
      await pumpEventQueue();

      expect(states, [busy]);
      expect(await cachedDates(), [confirmedDate]);
    });

    test('a bloc that starts closing as the date is written emits nothing '
        'more', () async {
      // Close starts as the write lands, so the outcome is ready before
      // bloc's own close has cancelled the handler, as in the delete's
      // closing test. The bloc's own check keeps it off a closing stream.
      late EventActionsBloc bloc;
      Future<void>? closing;
      cached.onLanded = () => closing = bloc.close();
      bloc = over(dating((_) => confirmedDate));
      final states = record(bloc);

      bloc.add(confirm);
      await pumpEventQueue();
      await closing;

      expect(states, [busy]);
      expect(await cachedDates(), [confirmedDate]);
    });

    test('a date write whose event is not cached is still done, and '
        'logged', () async {
      // Nothing cached to write it beside, or the sync queue owns the event.
      final bloc = over(
        dating((_) => confirmedDate.copyWith(id: 'd-9', eventId: 'e-9')),
      );
      addTearDown(bloc.close);

      bloc.add(const EventDateConfirmRequested('e-9', 'd-9'));
      final outcome = await answered(bloc);

      expect(outcome.result, EventActionResult.done);
      verify(() => logger.info(any())).called(1);
    });

    test(
      'a date write the cache throws on is still done, and logged',
      () async {
        // A session that has ended takes its repository with it.
        await cached.onDispose();
        final bloc = over(dating((_) => confirmedDate));
        addTearDown(bloc.close);

        bloc.add(confirm);
        final outcome = await answered(bloc);

        expect(outcome.result, EventActionResult.done);
        verifyWarnings(1);
      },
    );
  });
}
