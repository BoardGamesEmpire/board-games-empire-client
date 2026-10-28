import 'package:equatable/equatable.dart';

/// Input to the actions on an event's detail screen (#501).
sealed class EventActionsEvent extends Equatable {
  const EventActionsEvent();

  @override
  List<Object?> get props => [];
}

/// Delete the event [eventId].
///
/// The id is the one the screen shows, which a reconcile can move while it
/// is open (#499), so it travels with the request rather than with the bloc.
final class EventDeleteRequested extends EventActionsEvent {
  const EventDeleteRequested(this.eventId);

  final String eventId;

  @override
  List<Object?> get props => [eventId];
}

/// The person closed the last action's banner.
final class EventActionOutcomeDismissed extends EventActionsEvent {
  const EventActionOutcomeDismissed();
}
