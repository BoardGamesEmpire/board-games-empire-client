import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Input to the availability poll on an event's detail screen (#507).
///
/// Each names the event by the id the screen shows, which a reconcile can
/// move while it is open (#499), so the id travels with the request rather
/// than with the bloc, as the event actions' requests do.
sealed class EventPollEvent extends Equatable {
  const EventPollEvent();

  @override
  List<Object?> get props => [];
}

/// Read how the poll on the event [eventId] stands: when the screen opens,
/// and after each detail read. The bloc reads it again itself once a run of
/// votes ends, and a retry is [EventPollRetryRequested].
final class EventPollRequested extends EventPollEvent {
  const EventPollRequested(this.eventId);

  final String eventId;

  @override
  List<Object?> get props => [eventId];
}

/// The person asked to read the poll on the event [eventId] again, after a
/// read failed. Read as [EventPollRequested] is, and the state says so
/// while it runs (`EventPollState.refreshing`).
final class EventPollRetryRequested extends EventPollEvent {
  const EventPollRetryRequested(this.eventId);

  final String eventId;

  @override
  List<Object?> get props => [eventId];
}

/// The viewer answered [response] on the proposed date [occurrenceId] of the
/// event [eventId].
final class EventPollVoted extends EventPollEvent {
  const EventPollVoted(this.eventId, this.occurrenceId, this.response);

  final String eventId;
  final String occurrenceId;
  final AvailabilityResponse response;

  @override
  List<Object?> get props => [eventId, occurrenceId, response];
}

/// The person closed the last vote's banner.
final class EventPollOutcomeDismissed extends EventPollEvent {
  const EventPollOutcomeDismissed();
}
