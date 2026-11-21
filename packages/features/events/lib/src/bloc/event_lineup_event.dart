import 'package:equatable/equatable.dart';

/// Input to an event's lineup (#519).
///
/// Each names the event by the id the screen shows, which a reconcile can
/// move while it is open (#499), so the id travels with the request rather
/// than with the bloc.
sealed class EventLineupEvent extends Equatable {
  const EventLineupEvent();

  @override
  List<Object?> get props => [];
}

/// Read the lineup of the event [eventId]: when the screen opens, and after
/// each detail read. A retry is [EventLineupRetryRequested].
final class EventLineupRequested extends EventLineupEvent {
  const EventLineupRequested(this.eventId);

  final String eventId;

  @override
  List<Object?> get props => [eventId];
}

/// The person asked to read the lineup again, after a read failed. Read as
/// [EventLineupRequested] is, and the state says so while it runs
/// (`EventLineupState.refreshing`).
final class EventLineupRetryRequested extends EventLineupEvent {
  const EventLineupRetryRequested(this.eventId);

  final String eventId;

  @override
  List<Object?> get props => [eventId];
}
