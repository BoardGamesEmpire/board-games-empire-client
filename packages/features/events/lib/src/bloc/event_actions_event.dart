import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// Input to the actions on an event's detail screen (#501, #506).
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

// The date writes (#506). Each names the event by the id the screen shows,
// as [EventDeleteRequested] does, and the date by its own.

/// Add [draft] as a date of the event [eventId], at [sortOrder].
final class EventDateAddRequested extends EventActionsEvent {
  const EventDateAddRequested(
    this.eventId,
    this.draft, {
    required this.sortOrder,
  });

  final String eventId;
  final EventOccurrenceDraft draft;

  /// Where the new date falls among the event's, lowest first.
  final int sortOrder;

  @override
  List<Object?> get props => [eventId, draft, sortOrder];
}

/// Change the date [occurrenceId] of the event [eventId] as [update] says.
final class EventDateEditRequested extends EventActionsEvent {
  const EventDateEditRequested(this.eventId, this.occurrenceId, this.update);

  final String eventId;
  final String occurrenceId;
  final OccurrenceUpdate update;

  @override
  List<Object?> get props => [eventId, occurrenceId, update];
}

/// Confirm the proposed date [occurrenceId] of the event [eventId].
final class EventDateConfirmRequested extends EventActionsEvent {
  const EventDateConfirmRequested(this.eventId, this.occurrenceId);

  final String eventId;
  final String occurrenceId;

  @override
  List<Object?> get props => [eventId, occurrenceId];
}

/// Decline the proposed date [occurrenceId] of the event [eventId].
final class EventDateDeclineRequested extends EventActionsEvent {
  const EventDateDeclineRequested(this.eventId, this.occurrenceId);

  final String eventId;
  final String occurrenceId;

  @override
  List<Object?> get props => [eventId, occurrenceId];
}

/// Cancel the date [occurrenceId] of the event [eventId], giving [reason]
/// if there is one.
final class EventDateCancelRequested extends EventActionsEvent {
  const EventDateCancelRequested(
    this.eventId,
    this.occurrenceId, {
    this.reason,
  });

  final String eventId;
  final String occurrenceId;

  /// Sent trimmed, and not at all when blank
  /// ([EventRemoteDataSource.cancelOccurrence]).
  final String? reason;

  @override
  List<Object?> get props => [eventId, occurrenceId, reason];
}

/// Remove the date [occurrenceId] of the event [eventId].
///
/// [cancelFirst] for a Confirmed date (#446): cancel, then remove only if the
/// cancel was done. [reason] goes with that cancel.
final class EventDateRemoveRequested extends EventActionsEvent {
  const EventDateRemoveRequested(
    this.eventId,
    this.occurrenceId, {
    this.cancelFirst = false,
    this.reason,
  });

  final String eventId;
  final String occurrenceId;
  final bool cancelFirst;
  final String? reason;

  @override
  List<Object?> get props => [eventId, occurrenceId, cancelFirst, reason];
}

/// The person closed the last action's banner.
final class EventActionOutcomeDismissed extends EventActionsEvent {
  const EventActionOutcomeDismissed();
}
