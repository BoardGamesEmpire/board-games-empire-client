import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:events/src/bloc/edit_event_bloc.dart';
import 'package:events/src/bloc/edit_event_event.dart';
import 'package:events/src/bloc/edit_event_state.dart';
import 'package:events/src/edit/event_edit_controls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../support/fake_event_remote.dart';

class _MockEventRepository extends Mock implements EventRepository {}

class _MockBgeLogger extends Mock implements BgeLogger {}

final _at = DateTime.utc(2026, 11, 18);

Event _event({String title = 'Game night'}) => Event(
  id: 'ev_1',
  title: title,
  createdById: 'u_host',
  type: EventType.strategyNight,
  reach: Reach.friends,
  status: EventStatus.scheduled,
  schedulingMode: EventSchedulingMode.fixed,
  createdAt: _at,
  updatedAt: _at,
  description: 'Bring snacks',
  location: 'The back room',
  url: 'https://example.com/night',
);

EventPolicy _policy({
  GameAdditionMode mode = GameAdditionMode.requiresVote,
}) => EventPolicy(
  id: 'p_1',
  eventId: 'ev_1',
  allowMemberInvites: true,
  allowGuestInvites: false,
  restrictToGameCategories: false,
  requireHostApprovalToJoin: false,
  allowSpectators: false,
  strictCapacity: false,
  gameAdditionMode: mode,
  restrictToAttendeePool: false,
  voteThresholdType: VoteThresholdType.supermajority,
  voteThresholdValue: 75,
  voteQuorumType: VoteQuorumType.percentOfAttendees,
  voteQuorumValue: 40,
  votingWindowHours: 48,
  voteEligibility: VoteEligibility.allAttendees,
  interestedWeight: InterestedWeight.asAbstain,
  createdAt: _at,
  updatedAt: _at,
);

/// The rules as [_policy] has them.
const _sameRules = EventPolicyDraft(
  gameAdditionMode: GameAdditionMode.requiresVote,
  voteThresholdType: VoteThresholdType.supermajority,
  voteThresholdValue: 75,
  voteQuorumType: VoteQuorumType.percentOfAttendees,
  voteQuorumValue: 40,
  votingWindowHours: 48,
);

/// How games get added changed, nothing else.
const _directRules = EventPolicyDraft(
  gameAdditionMode: GameAdditionMode.direct,
);

EventEditValues _values({
  String title = 'Game night',
  EventType type = EventType.strategyNight,
  Reach reach = Reach.friends,
  EventPolicyDraft? rules,
}) => EventEditValues(
  title: title,
  description: 'Bring snacks',
  location: 'The back room',
  url: 'https://example.com/night',
  type: type,
  reach: reach,
  rules: rules,
);

const _refused = EventWriteRefusedException('no', statusCode: 403);

void main() {
  late _MockEventRepository repository;
  late _MockBgeLogger logger;
  late List<String> calls;

  setUp(() {
    repository = _MockEventRepository();
    logger = _MockBgeLogger();
    calls = [];
    registerFallbackValue(_event());
    registerFallbackValue(_policy());
    when(() => repository.cacheEventRow(any())).thenAnswer((_) async => true);
    when(
      () => repository.cacheEventPolicy(any()),
    ).thenAnswer((_) async => true);
  });

  /// A server answering each edit as the callbacks do; a missing one
  /// answers with the event or rules it was given.
  FakeEventRemote serving({
    FutureOr<Event> Function(EventEditRequest request)? event,
    FutureOr<EventPolicy> Function(EventEditRequest request)? policy,
  }) => FakeEventRemote(
    (_) => throw UnimplementedError('the edit reads nothing'),
    eventEdited: (request) {
      calls.add(request.call);
      return event?.call(request) ?? _event(title: 'Renamed');
    },
    policyEdited: (request) {
      calls.add(request.call);
      return policy?.call(request) ?? _policy(mode: GameAdditionMode.direct);
    },
  );

  EditEventBloc build(
    FakeEventRemote remote, {
    EventPolicy? policy,
    bool withPolicy = true,
    Future<bool> Function()? confirmSession,
  }) => EditEventBloc(
    event: _event(),
    policy: withPolicy ? (policy ?? _policy()) : null,
    remote: remote,
    repository: repository,
    confirmSession: confirmSession,
    logger: logger,
  );

  blocTest<EditEventBloc, EditEventState>(
    'an unchanged submit saves nothing and sends nothing',
    build: () => build(serving()),
    act: (bloc) => bloc.add(EditEventSubmitted(_values(rules: _sameRules))),
    expect: () => [const EditEventSaved(changed: false)],
    verify: (bloc) {
      expect(calls, isEmpty);
      verifyNever(() => repository.cacheEventRow(any()));
    },
  );

  late FakeEventRemote remote;

  blocTest<EditEventBloc, EditEventState>(
    'a details-only change sends one PATCH and caches its answer',
    build: () => build(remote = serving()),
    act: (bloc) => bloc.add(
      EditEventSubmitted(_values(title: 'Renamed', rules: _sameRules)),
    ),
    expect: () => [const EditEventSaving(), const EditEventSaved()],
    verify: (bloc) {
      expect(calls, ['event']);
      // Only the title is carried.
      expect(fieldsSentBy(remote.eventEdits.single.update!), {
        EventEditField.title,
      });
      verify(() => repository.cacheEventRow(_event(title: 'Renamed')))
          .called(1);
      verifyNever(() => repository.cacheEventPolicy(any()));
    },
  );

  blocTest<EditEventBloc, EditEventState>(
    'a rules-only change sends only the policy PATCH and caches it',
    build: () => build(serving()),
    act: (bloc) => bloc.add(EditEventSubmitted(_values(rules: _directRules))),
    expect: () => [const EditEventSaving(), const EditEventSaved()],
    verify: (bloc) {
      expect(calls, ['policy']);
      verify(
        () =>
            repository.cacheEventPolicy(_policy(mode: GameAdditionMode.direct)),
      ).called(1);
      verifyNever(() => repository.cacheEventRow(any()));
    },
  );

  blocTest<EditEventBloc, EditEventState>(
    'both change: the event goes first, then the rules',
    build: () => build(serving()),
    act: (bloc) => bloc.add(
      EditEventSubmitted(_values(title: 'Renamed', rules: _directRules)),
    ),
    expect: () => [const EditEventSaving(), const EditEventSaved()],
    verify: (bloc) => expect(calls, ['event', 'policy']),
  );

  blocTest<EditEventBloc, EditEventState>(
    'rules are not sent when none were cached or the form has none',
    build: () => build(serving(), withPolicy: false),
    act: (bloc) => bloc.add(EditEventSubmitted(_values(rules: _directRules))),
    expect: () => [const EditEventSaved(changed: false)],
    verify: (bloc) => expect(calls, isEmpty),
  );

  group('the rules failing after the details saved', () {
    late FakeEventRemote remote;
    late EditEventBloc bloc;

    setUp(() {
      remote = serving(policy: (_) => throw _refused);
      bloc = build(remote);
      addTearDown(bloc.close);
    });

    test('says so, and the next submit sends only the rules', () async {
      final states = <EditEventState>[];
      final sub = bloc.stream.listen(states.add);
      addTearDown(sub.cancel);
      final values = _values(title: 'Renamed', rules: _directRules);

      bloc.add(EditEventSubmitted(values));
      await pumpEventQueue();
      expect(states, [
        const EditEventSaving(),
        const EditEventFailed(EditEventFailure.refused, detailsSaved: true),
      ]);
      verify(() => repository.cacheEventRow(any())).called(1);
      expect(calls, ['event', 'policy']);

      calls.clear();
      states.clear();
      bloc.add(EditEventSubmitted(values));
      await pumpEventQueue();
      expect(calls, ['policy']);
      // The resend carries the rules' change, and no event field.
      expect(rulesFieldsSentBy(remote.eventEdits.last.policy!), {
        EventEditField.gameAdditionMode,
      });
      expect(
        states.last,
        const EditEventFailed(
          EditEventFailure.refused,
          detailsSaved: true,
        ),
      );
      expect(remote.eventEdits.where((r) => r.call == 'event'), hasLength(1));
    });
  });

  test(
    'nothing left to send after the details saved still says updated',
    () async {
      final bloc = build(serving(policy: (_) => throw _refused));
      addTearDown(bloc.close);

      bloc.add(
        EditEventSubmitted(_values(title: 'Renamed', rules: _directRules)),
      );
      await pumpEventQueue();
      expect(
        bloc.state,
        const EditEventFailed(EditEventFailure.refused, detailsSaved: true),
      );

      // The rule put back as it was: nothing is sent, and the details this
      // page saved are still the news.
      calls.clear();
      bloc.add(
        EditEventSubmitted(_values(title: 'Renamed', rules: _sameRules)),
      );
      await pumpEventQueue();
      expect(calls, isEmpty);
      expect(bloc.state, const EditEventSaved());
    },
  );

  test('a landed event send drops its fields from the resend', () async {
    var eventFails = true;
    final remote = serving(
      event: (_) => eventFails
          ? throw const EventRemoteTransientException('x')
          : _event(title: 'Renamed'),
      policy: (_) => throw _refused,
    );
    final bloc = build(remote);
    addTearDown(bloc.close);
    final values = _values(title: 'Renamed', rules: _directRules);

    // The title may have been written, so it is remembered.
    bloc.add(EditEventSubmitted(values));
    await pumpEventQueue();
    expect(
      bloc.state,
      const EditEventFailed(EditEventFailure.offline, unsettled: true),
    );
    expect(calls, ['event']);

    // The event lands and the rules are refused.
    eventFails = false;
    calls.clear();
    bloc.add(EditEventSubmitted(values));
    await pumpEventQueue();
    expect(calls, ['event', 'policy']);

    // The title, kept, is no longer owed.
    calls.clear();
    bloc.add(EditEventSubmitted(values));
    await pumpEventQueue();
    expect(calls, ['policy']);
  });

  test(
    'a saved type and reach are not sent again after a partial save',
    () async {
      final remote = serving(
        event: (_) => _event().copyWith(
          type: EventType.familyNight,
          reach: Reach.public,
        ),
        policy: (_) => throw _refused,
      );
      final bloc = build(remote);
      addTearDown(bloc.close);
      final values = _values(
        type: EventType.familyNight,
        reach: Reach.public,
        rules: _directRules,
      );

      bloc.add(EditEventSubmitted(values));
      await pumpEventQueue();
      expect(calls, ['event', 'policy']);
      expect(
        remote.eventEdits.first.update,
        EventUpdate(type: EventType.familyNight, reach: Reach.public),
      );

      // Both are the starting point now, so only the rules are left to send.
      calls.clear();
      bloc.add(EditEventSubmitted(values));
      await pumpEventQueue();
      expect(calls, ['policy']);
    },
  );

  test("another device's edit is not sent back after a partial save", () async {
    final remote = serving(
      // Device B changed the location since the page opened.
      event: (_) => _event(title: 'Renamed').copyWith(location: 'B place'),
      policy: (_) => throw _refused,
    );
    final bloc = build(remote);
    addTearDown(bloc.close);
    final values = _values(title: 'Renamed', rules: _directRules);

    bloc.add(EditEventSubmitted(values));
    await pumpEventQueue();
    expect(calls, ['event', 'policy']);
    expect(remote.eventEdits.first.update?.location, isNull);

    calls.clear();
    bloc.add(EditEventSubmitted(values));
    await pumpEventQueue();
    expect(calls, ['policy']);
  });

  test('EVENT_POLICY_INVALID on the rules keeps the details saved', () async {
    final bloc = build(
      serving(
        policy: (_) => throw const EventWriteConflictException(
          'bad',
          statusCode: 400,
          code: EventWriteConflictException.policyInvalid,
        ),
      ),
    );
    addTearDown(bloc.close);

    bloc.add(
      EditEventSubmitted(_values(title: 'Renamed', rules: _directRules)),
    );
    await pumpEventQueue();
    expect(
      bloc.state,
      const EditEventFailed(EditEventFailure.rulesInvalid, detailsSaved: true),
    );
  });

  group('a transient failure', () {
    test('re-sends its fields even when changed back', () async {
      final remote = serving(
        event: (_) => throw const EventRemoteTransientException('offline'),
      );
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(EditEventSubmitted(_values(title: 'Renamed')));
      await pumpEventQueue();
      expect(
        bloc.state,
        const EditEventFailed(EditEventFailure.offline, unsettled: true),
      );

      bloc.add(EditEventSubmitted(_values()));
      await pumpEventQueue();
      expect(remote.eventEdits, hasLength(2));
      expect(remote.eventEdits.last.update?.title, 'Game night');
    });

    test("a 4xx doesn't remember its fields", () async {
      final remote = serving(
        event: (_) => throw const EventRemoteTransientException(
          'slow down',
          statusCode: 429,
        ),
      );
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(EditEventSubmitted(_values(title: 'Renamed')));
      await pumpEventQueue();
      expect(bloc.state, const EditEventFailed(EditEventFailure.offline));

      bloc.add(EditEventSubmitted(_values()));
      await pumpEventQueue();
      expect(remote.eventEdits, hasLength(1));
      expect(bloc.state, const EditEventSaved(changed: false));
    });

    test('a 5xx remembers its fields', () async {
      final remote = serving(
        event: (_) => throw const EventRemoteTransientException(
          'down',
          statusCode: 503,
        ),
      );
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(EditEventSubmitted(_values(title: 'Renamed')));
      await pumpEventQueue();
      expect(
        bloc.state,
        const EditEventFailed(EditEventFailure.offline, unsettled: true),
      );
      bloc.add(EditEventSubmitted(_values()));
      await pumpEventQueue();
      expect(remote.eventEdits, hasLength(2));
    });

    test('a resend turned away is still unsettled', () async {
      // The 503's title may be on the server; the 403 doesn't undo it.
      var answer = const EventRemoteTransientException('down', statusCode: 503);
      final remote = serving(event: (_) => throw answer);
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(EditEventSubmitted(_values(title: 'Renamed')));
      await pumpEventQueue();
      answer = const EventRemoteTransientException('slow', statusCode: 429);
      bloc.add(EditEventSubmitted(_values(title: 'Renamed')));
      await pumpEventQueue();
      expect(
        bloc.state,
        const EditEventFailed(EditEventFailure.offline, unsettled: true),
      );
    });
  });

  test(
    'a 2xx the remote could not read is unexpected, and remembered',
    () async {
      final remote = serving(
        event: (_) => throw const EventRemotePermanentException(
          'unreadable',
          statusCode: 200,
        ),
      );
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(EditEventSubmitted(_values(title: 'Renamed')));
      await pumpEventQueue();
      expect(
        bloc.state,
        const EditEventFailed(EditEventFailure.unexpected, unsettled: true),
      );

      bloc.add(EditEventSubmitted(_values()));
      await pumpEventQueue();
      expect(remote.eventEdits, hasLength(2));
    },
  );

  test('rules answered 2xx unreadably after the details saved', () async {
    final bloc = build(
      serving(
        policy: (_) => throw const EventRemotePermanentException(
          'unreadable',
          statusCode: 200,
        ),
      ),
    );
    addTearDown(bloc.close);

    bloc.add(
      EditEventSubmitted(_values(title: 'Renamed', rules: _directRules)),
    );
    await pumpEventQueue();
    expect(
      bloc.state,
      const EditEventFailed(
        EditEventFailure.unexpected,
        detailsSaved: true,
        unsettled: true,
      ),
    );
  });

  group('each answer has its failure, and its fields are not remembered', () {
    const answers = <String, (EventRemoteException, EditEventFailure)>{
      'EVENT_POLICY_INVALID is rulesInvalid': (
        EventWriteConflictException(
          'bad',
          statusCode: 400,
          code: EventWriteConflictException.policyInvalid,
        ),
        EditEventFailure.rulesInvalid,
      ),
      'another coded conflict is invalid': (
        EventWriteConflictException('bad', statusCode: 400, code: 'OTHER'),
        EditEventFailure.invalid,
      ),
      'a 404 is gone': (
        EventRemoteNotFoundException('gone', statusCode: 404),
        EditEventFailure.gone,
      ),
      'a 403 is refused': (_refused, EditEventFailure.refused),
      'a validation 400 is invalid': (
        EventRemotePermanentException('bad', statusCode: 400),
        EditEventFailure.invalid,
      ),
      'anything else is unexpected': (
        EventRemotePermanentException('odd', statusCode: 418),
        EditEventFailure.unexpected,
      ),
    };

    for (final MapEntry(key: name, value: (error, failure))
        in answers.entries) {
      test(name, () async {
        final remote = serving(event: (_) => throw error);
        final bloc = build(remote);
        addTearDown(bloc.close);

        bloc.add(EditEventSubmitted(_values(title: 'Renamed')));
        await pumpEventQueue();
        expect(bloc.state, EditEventFailed(failure));
        verifyNever(() => repository.cacheEventRow(any()));

        // Changed back, nothing is left to send.
        bloc.add(EditEventSubmitted(_values()));
        await pumpEventQueue();
        expect(remote.eventEdits, hasLength(1));
      });
    }

    test('a failed event stops before the rules', () async {
      final remote = serving(event: (_) => throw _refused);
      final bloc = build(remote);
      addTearDown(bloc.close);

      bloc.add(
        EditEventSubmitted(_values(title: 'Renamed', rules: _directRules)),
      );
      await pumpEventQueue();
      expect(bloc.state, const EditEventFailed(EditEventFailure.refused));
      expect(calls, ['event']);
    });
  });

  group('a cache write that fails or declines', () {
    test('that throws is logged, and the outcome stands', () async {
      when(() => repository.cacheEventRow(any())).thenThrow(StateError('x'));
      when(
        () => repository.cacheEventPolicy(any()),
      ).thenThrow(StateError('y'));
      final bloc = build(serving());
      addTearDown(bloc.close);

      bloc.add(
        EditEventSubmitted(_values(title: 'Renamed', rules: _directRules)),
      );
      await pumpEventQueue();
      expect(bloc.state, const EditEventSaved());
      verify(
        () => logger.warn(
          any(),
          error: any(named: 'error'),
          stackTrace: any(named: 'stackTrace'),
        ),
      ).called(2);
    });

    test('that returns false is logged, and the outcome stands', () async {
      when(() => repository.cacheEventRow(any()))
          .thenAnswer((_) async => false);
      when(
        () => repository.cacheEventPolicy(any()),
      ).thenAnswer((_) async => false);
      final bloc = build(serving());
      addTearDown(bloc.close);

      bloc.add(
        EditEventSubmitted(_values(title: 'Renamed', rules: _directRules)),
      );
      await pumpEventQueue();
      expect(bloc.state, const EditEventSaved());
      verify(() => logger.info(any())).called(2);
    });
  });

  blocTest<EditEventBloc, EditEventState>(
    'a session that changed sends nothing',
    build: () => build(serving(), confirmSession: () async => false),
    act: (bloc) => bloc.add(EditEventSubmitted(_values(title: 'Renamed'))),
    expect: () => [
      const EditEventSaving(),
      const EditEventFailed(EditEventFailure.unexpected),
    ],
    verify: (bloc) => expect(calls, isEmpty),
  );

  test('the session is asked again before the rules go out', () async {
    // The details' answer can land after a sign-in in another tab, and the
    // rules would then go out under that account's token (#432).
    final answers = [true, false];
    var asked = 0;
    final bloc = build(
      serving(),
      confirmSession: () async => answers[asked++],
    );
    addTearDown(bloc.close);

    bloc.add(
      EditEventSubmitted(_values(title: 'Renamed', rules: _directRules)),
    );
    await pumpEventQueue();
    expect(
      bloc.state,
      const EditEventFailed(EditEventFailure.unexpected, detailsSaved: true),
    );
    expect(calls, ['event']);
    expect(asked, 2);
  });

  blocTest<EditEventBloc, EditEventState>(
    'rules sent alone ask the session once',
    build: () {
      var asked = 0;
      addTearDown(() => expect(asked, 1));
      return build(
        serving(),
        confirmSession: () async {
          asked++;
          return true;
        },
      );
    },
    act: (bloc) => bloc.add(EditEventSubmitted(_values(rules: _directRules))),
    expect: () => [const EditEventSaving(), const EditEventSaved()],
    verify: (bloc) => expect(calls, ['policy']),
  );

  test('the save is under way while the session is checked', () async {
    // A page left now sees a save on its way, and keeps the bloc until it
    // settles (#464).
    final confirm = Completer<bool>();
    final bloc = build(serving(), confirmSession: () => confirm.future);
    addTearDown(bloc.close);

    bloc.add(EditEventSubmitted(_values(title: 'Renamed')));
    await pumpEventQueue();
    expect(bloc.state, const EditEventSaving());
    expect(calls, isEmpty);

    confirm.complete(true);
    await pumpEventQueue();
    expect(bloc.state, const EditEventSaved());
    expect(calls, ['event']);
  });

  test('rules saved with none to read back are saved, uncached', () async {
    // A viewer who may change the rules but not read them (backend#796).
    final remote = FakeEventRemote(
      (_) => throw UnimplementedError('the edit reads nothing'),
      policyEdited: (request) {
        calls.add(request.call);
        return null;
      },
    );
    final bloc = build(remote);
    addTearDown(bloc.close);

    bloc.add(EditEventSubmitted(_values(rules: _directRules)));
    await pumpEventQueue();
    expect(bloc.state, const EditEventSaved());
    expect(calls, ['policy']);
    verifyNever(() => repository.cacheEventPolicy(any()));
  });

  blocTest<EditEventBloc, EditEventState>(
    'an edit retires a failure',
    build: () => build(serving(event: (_) => throw _refused)),
    act: (bloc) async {
      bloc.add(EditEventSubmitted(_values(title: 'Renamed')));
      await pumpEventQueue();
      bloc.add(const EditEventEdited());
    },
    expect: () => [
      const EditEventSaving(),
      const EditEventFailed(EditEventFailure.refused),
      const EditEventEditing(),
    ],
  );

  blocTest<EditEventBloc, EditEventState>(
    'saved is final: a submit after it does nothing',
    build: () => build(serving()),
    act: (bloc) async {
      bloc.add(EditEventSubmitted(_values(title: 'Renamed')));
      await pumpEventQueue();
      bloc.add(EditEventSubmitted(_values(title: 'Again')));
    },
    expect: () => [const EditEventSaving(), const EditEventSaved()],
    verify: (bloc) => expect(calls, ['event']),
  );

  blocTest<EditEventBloc, EditEventState>(
    'a double submit sends once',
    build: () {
      final gate = Completer<Event>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete(_event(title: 'Renamed'));
      });
      return build(serving(event: (_) => gate.future));
    },
    act: (bloc) async {
      bloc
        ..add(EditEventSubmitted(_values(title: 'Renamed')))
        ..add(EditEventSubmitted(_values(title: 'Renamed')));
      await pumpEventQueue();
    },
    expect: () => [const EditEventSaving()],
    verify: (bloc) => expect(calls, ['event']),
  );
}
