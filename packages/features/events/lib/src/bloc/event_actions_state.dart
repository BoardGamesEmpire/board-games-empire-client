import 'package:equatable/equatable.dart';
import 'package:network_interface/network_interface.dart';

import '../detail/event_actions.dart';

/// How an action on an event ended (#501).
enum EventActionResult {
  /// The server did it. The cache is written after the outcome is out.
  done,

  /// The server has no live event with that id: it was deleted, perhaps by
  /// an earlier delete from this device whose answer was lost (#501). The
  /// cache is written after the outcome is out, as for done.
  gone,

  /// The server refused it with a 403. The outcome's error says how.
  refused,

  /// No answer that says what happened, or the request never went out. The
  /// outcome's error says why, when there is one.
  failed,
}

/// The last event action's outcome, for the detail screen (#501).
final class EventActionOutcome extends Equatable {
  const EventActionOutcome({
    required this.action,
    required this.result,
    this.error,
  });

  final EventAction action;
  final EventActionResult result;

  /// What the action ended with. Null when it was done, and when it failed
  /// before the request went out.
  final Object? error;

  /// Whether the detail should be read again: a refusal, or a failure the
  /// request itself ended in that wasn't transient.
  ///
  /// A refusal says the viewer's role may have changed on another device,
  /// and a failure that isn't transient may have been a done this device
  /// could not read. A failure before the request went out, from a session
  /// that no longer matches or a cache that could not be read, has no error
  /// and isn't read again: nothing reached the server, and a read would ask
  /// the same session.
  bool get rereads => switch (result) {
    EventActionResult.refused => true,
    EventActionResult.failed =>
      error != null && error is! EventRemoteTransientException,
    EventActionResult.done || EventActionResult.gone => false,
  };

  @override
  List<Object?> get props => [action, result, error];
}

/// The actions on one event detail screen (#501).
final class EventActionsState extends Equatable {
  const EventActionsState({this.busy = false, this.outcome});

  /// Whether a request is on its way.
  final bool busy;

  /// What the last request answered, until dismissed or replaced.
  final EventActionOutcome? outcome;

  @override
  List<Object?> get props => [busy, outcome];
}
