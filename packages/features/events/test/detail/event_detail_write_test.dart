import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:events/src/bloc/event_actions_bloc.dart';
import 'package:events/src/bloc/event_actions_event.dart';
import 'package:events/src/bloc/event_actions_state.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_event.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/detail/event_actions.dart';
import 'package:events/src/detail/event_detail_write.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import '../support/event_list_items.dart';

class _MockActions extends MockBloc<EventActionsEvent, EventActionsState>
    implements EventActionsBloc {}

class _MockDetail extends MockBloc<EventDetailEvent, EventDetailState>
    implements EventDetailBloc {}

/// The event [id] as the detail shows it, with a read running or not.
EventDetailReady _ready({String id = 'e', bool reading = false}) =>
    EventDetailReady(
      detail: EventDetail(
        snapshot: EventSnapshot(event: item(id).event, occurrences: const []),
      ),
      actions: const {EventAction.delete},
      reading: reading,
    );

/// The detail screen's one path for a write (#751): ask, wait for a running
/// read, re-check against the detail as it is then, and add what the check
/// decides to the actions bloc.
void main() {
  late _MockActions actions;
  late _MockDetail detail;

  setUpAll(() {
    registerFallbackValue(const EventActionOutcomeDismissed());
  });

  setUp(() {
    actions = _MockActions();
    detail = _MockDetail();
    when(() => actions.isClosed).thenReturn(false);
    when(() => actions.state).thenReturn(const EventActionsState());
    whenListen(
      detail,
      const Stream<EventDetailState>.empty(),
      initialState: _ready(),
    );
  });

  /// Draws both blocs over a [Builder], and answers its context.
  Future<BuildContext> pumpContext(WidgetTester tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MultiBlocProvider(
        providers: [
          BlocProvider<EventActionsBloc>.value(value: actions),
          BlocProvider<EventDetailBloc>.value(value: detail),
        ],
        child: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    return captured;
  }

  /// Everything added to the actions bloc, in order. Fails where nothing was.
  List<Object?> added() => verify(() => actions.add(captureAny())).captured;

  /// A check that sends a delete of the event the detail shows then.
  DetailWriteCheck sendDelete(EventDetailReady state, Object _) =>
      SendWrite(EventDeleteRequested(state.detail.snapshot.event.id));

  testWidgets('answers false and adds nothing when ask answers null', (
    tester,
  ) async {
    final context = await pumpContext(tester);
    var checked = false;

    final sent = await sendDetailWrite<String>(
      context,
      ask: () async => null,
      check: (state, answer) {
        checked = true;
        return sendDelete(state, answer);
      },
    );

    expect(sent, isFalse);
    expect(checked, isFalse);
    verifyNever(() => actions.add(any()));
  });

  testWidgets('waits for a running read to end before checking', (
    tester,
  ) async {
    final reads = StreamController<EventDetailState>();
    addTearDown(reads.close);
    whenListen(detail, reads.stream, initialState: _ready(reading: true));
    final context = await pumpContext(tester);
    EventDetailReady? seen;

    final sending = sendDetailWrite<String>(
      context,
      ask: () async => 'yes',
      check: (state, answer) {
        seen = state;
        return sendDelete(state, answer);
      },
    );
    await tester.pump();

    expect(seen, isNull);
    verifyNever(() => actions.add(any()));

    // The read ends with the event under the id a reconcile moved it to.
    reads.add(_ready(id: 'e-moved'));

    expect(await sending, isTrue);
    expect(seen, _ready(id: 'e-moved'));
    expect(added(), [const EventDeleteRequested('e-moved')]);
  });

  testWidgets('adds the request a SendWrite carries', (tester) async {
    final context = await pumpContext(tester);

    final sent = await sendDetailWrite<String>(
      context,
      ask: () async => 'yes',
      check: sendDelete,
    );

    expect(sent, isTrue);
    expect(added(), [const EventDeleteRequested('e')]);
  });

  testWidgets('adds the drop a DropWrite carries, and answers false', (
    tester,
  ) async {
    final context = await pumpContext(tester);

    final sent = await sendDetailWrite<String>(
      context,
      ask: () async => 'yes',
      check: (_, _) =>
          const DropWrite(EventWriteDropped(EventAction.removeDate)),
    );

    expect(sent, isFalse);
    expect(added(), [const EventWriteDropped(EventAction.removeDate)]);
  });

  testWidgets('a SkipWrite adds nothing', (tester) async {
    final context = await pumpContext(tester);

    final sent = await sendDetailWrite<String>(
      context,
      ask: () async => 'yes',
      check: (_, _) => const SkipWrite(),
    );

    expect(sent, isFalse);
    verifyNever(() => actions.add(any()));
  });

  testWidgets('adds nothing once the actions bloc closed while asking', (
    tester,
  ) async {
    final context = await pumpContext(tester);
    final answer = Completer<String?>();
    var checked = false;

    final sending = sendDetailWrite<String>(
      context,
      ask: () => answer.future,
      check: (state, answer) {
        checked = true;
        return sendDelete(state, answer);
      },
    );
    when(() => actions.isClosed).thenReturn(true);
    answer.complete('yes');

    expect(await sending, isFalse);
    expect(checked, isFalse);
    verifyNever(() => actions.add(any()));
  });

  testWidgets('adds nothing while a request is out', (tester) async {
    when(() => actions.state).thenReturn(const EventActionsState(busy: true));
    final context = await pumpContext(tester);

    final sent = await sendDetailWrite<String>(
      context,
      ask: () async => 'yes',
      check: sendDelete,
    );

    expect(sent, isFalse);
    verifyNever(() => actions.add(any()));
  });

  testWidgets('adds a drop even while a request is out', (tester) async {
    // The busy check is the last, and only a request waits on it: the bloc
    // ignores a drop while a request is out, whose own outcome says what
    // happened.
    when(() => actions.state).thenReturn(const EventActionsState(busy: true));
    final context = await pumpContext(tester);

    final sent = await sendDetailWrite<String>(
      context,
      ask: () async => 'yes',
      check: (_, _) =>
          const DropWrite(EventWriteDropped(EventAction.removeDate)),
    );

    expect(sent, isFalse);
    expect(added(), [const EventWriteDropped(EventAction.removeDate)]);
  });

  testWidgets('adds nothing when the detail is no longer ready', (
    tester,
  ) async {
    final reads = StreamController<EventDetailState>();
    addTearDown(reads.close);
    whenListen(detail, reads.stream, initialState: _ready(reading: true));
    final context = await pumpContext(tester);
    var checked = false;

    final sending = sendDetailWrite<String>(
      context,
      ask: () async => 'yes',
      check: (state, answer) {
        checked = true;
        return sendDelete(state, answer);
      },
    );
    // The read found the event gone.
    reads.add(const EventDetailNotFound());

    expect(await sending, isFalse);
    expect(checked, isFalse);
    verifyNever(() => actions.add(any()));
  });

  testWidgets('reads both blocs before asking, so a page rebuilt without '
      'the control still sends', (tester) async {
    final context = await pumpContext(tester);
    final answer = Completer<String?>();

    final sending = sendDetailWrite<String>(
      context,
      ask: () => answer.future,
      check: sendDelete,
    );
    // The page under the dialog rebuilt without the control, and took its
    // context and the blocs' providers with it.
    await tester.pumpWidget(const SizedBox.shrink());
    expect(context.mounted, isFalse);
    answer.complete('yes');

    expect(await sending, isTrue);
    expect(added(), [const EventDeleteRequested('e')]);
  });
}
