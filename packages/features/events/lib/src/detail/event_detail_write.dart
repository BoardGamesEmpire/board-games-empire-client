import 'package:events/src/bloc/event_actions_bloc.dart';
import 'package:events/src/bloc/event_actions_event.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// What a write's re-check decided, once its dialog closed and any running
/// read ended (#751).
sealed class DetailWriteCheck {
  const DetailWriteCheck();
}

/// Send [request]: the write still stands against the detail as it is then.
final class SendWrite extends DetailWriteCheck {
  const SendWrite(this.request);

  final EventActionsEvent request;
}

/// Send nothing, and say so with [dropped]'s banner: while the dialog was
/// open, a sync changed the event or the viewer's grant, or the clock moved
/// on (a date passed, or one ended and moved the status on), and the page
/// already shows it without the control. Silent, a screen reader would hear
/// nothing happen (#655).
final class DropWrite extends DetailWriteCheck {
  const DropWrite(this.dropped);

  final EventWriteDropped dropped;
}

/// Nothing to send and nothing to say: an unchanged note or answer.
final class SkipWrite extends DetailWriteCheck {
  const SkipWrite();
}

/// [detail]'s state once no read is running: now, or when the running one
/// ends. Its last state if it closes first. Every write [sendDetailWrite]
/// sends waits on it.
Future<EventDetailState> readEnded(EventDetailBloc detail) {
  bool ended(EventDetailState state) =>
      state is! EventDetailReady || !state.reading;

  if (ended(detail.state)) return Future.value(detail.state);
  return detail.stream.firstWhere(ended, orElse: () => detail.state);
}

/// Sends one of the event detail's writes (#751): reads both blocs from
/// [context] before anything is awaited, asks with [ask], waits for any
/// running read, re-checks with [check] against the detail as it is then,
/// and adds what [check] decides to the `EventActionsBloc`.
///
/// [ask] opens the write's dialog, or answers at once for a write that has
/// none, and answers null when nothing is to be sent. It starts before
/// anything is awaited, so it can still read [context] before its own
/// dialog opens.
///
/// A read can have started while the dialog was open, and the write waits
/// for it to end: the read's answer landing after the write would put the
/// event back as it was (#501, #589). [check] then sees the event as the
/// detail shows it, whose id a reconcile can have moved (#499).
///
/// Answers whether a request was added: false when [ask] answers null, the
/// actions bloc closed meanwhile, the detail isn't [EventDetailReady],
/// [check] drops or skips, or a request is already out
/// (`EventActionsState.busy`).
///
/// The busy check runs last, and holds back only a request. One request goes
/// at a time, and the bloc ignores one added while another is out. A press
/// before a frame showed another control's request out gets here, and has to
/// hear that it sent nothing, or a control held pressed while what it sent
/// is out, as the RSVP's are, would stay held. A drop is added even then,
/// and the bloc ignores that too while a request is out, whose own outcome
/// says what happened. A write whose control holds nothing while its request
/// is out doesn't use what this answers, so for it nobody sees a difference.
Future<bool> sendDetailWrite<T extends Object>(
  BuildContext context, {
  required Future<T?> Function() ask,
  required DetailWriteCheck Function(EventDetailReady state, T answer) check,
}) async {
  // Read before the dialog opens: the page under it can rebuild without
  // the control, and take the context it was asked from with it.
  final actions = context.read<EventActionsBloc>();
  final detail = context.read<EventDetailBloc>();
  final answer = await ask();
  if (answer == null || actions.isClosed) return false;

  final state = await readEnded(detail);
  if (state is! EventDetailReady || actions.isClosed) return false;

  switch (check(state, answer)) {
    case SkipWrite():
      return false;
    case DropWrite(:final dropped):
      actions.add(dropped);
      return false;
    case SendWrite(:final request):
      if (actions.state.busy) return false;
      actions.add(request);
      return true;
  }
}
