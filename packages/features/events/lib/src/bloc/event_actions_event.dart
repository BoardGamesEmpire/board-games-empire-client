import 'package:equatable/equatable.dart';
import 'package:events/src/bloc/event_actions_state.dart';
import 'package:events/src/detail/event_actions.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// Input to the actions on an event's detail screen: the delete (#501), the
/// date writes (#506) and the event's status writes (#502).
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

/// Confirm the proposed date [occurrenceId] of the event [eventId], then
/// decline each date of [decline] (#507).
final class EventDateConfirmRequested extends EventActionsEvent {
  const EventDateConfirmRequested(
    this.eventId,
    this.occurrenceId, {
    this.decline = const [],
  });

  final String eventId;
  final String occurrenceId;

  /// The event's other Proposed dates to decline once the confirm is done,
  /// in the order they go out. A declined date can't be proposed again, so
  /// the screen sends only the ones the person chose to.
  final List<String> decline;

  @override
  List<Object?> get props => [eventId, occurrenceId, decline];
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

// The event's own status writes (#502). Each names the event by the id the
// screen shows, as [EventDeleteRequested] does.

/// Call the event [eventId] off, giving [reason] if there is one.
final class EventCancelRequested extends EventActionsEvent {
  const EventCancelRequested(this.eventId, {this.reason});

  final String eventId;

  /// Sent trimmed, and not at all when blank
  /// ([EventRemoteDataSource.cancelEvent]).
  final String? reason;

  @override
  List<Object?> get props => [eventId, reason];
}

/// Reopen the cancelled event [eventId].
final class EventReopenRequested extends EventActionsEvent {
  const EventReopenRequested(this.eventId);

  final String eventId;

  @override
  List<Object?> get props => [eventId];
}

/// Put the event [eventId] away.
final class EventArchiveRequested extends EventActionsEvent {
  const EventArchiveRequested(this.eventId);

  final String eventId;

  @override
  List<Object?> get props => [eventId];
}

/// Take the archived event [eventId] out again.
final class EventUnarchiveRequested extends EventActionsEvent {
  const EventUnarchiveRequested(this.eventId);

  final String eventId;

  @override
  List<Object?> get props => [eventId];
}

/// Answer the viewer's own invitation to [eventId] with [status] (#508).
/// [attendeeId] is the viewer's row on the event's roster.
final class EventRsvpRequested extends EventActionsEvent {
  const EventRsvpRequested(
    this.eventId,
    this.attendeeId,
    this.status, {
    this.notes,
  });

  final String eventId;
  final String attendeeId;
  final EventParticipationStatus status;

  /// Null leaves the note as it is; '' clears it (#508).
  final String? notes;

  @override
  List<Object?> get props => [eventId, attendeeId, status, notes];
}

/// Add the user [userId] to [eventId]'s roster as [role] (#510). [name] is
/// the person's name, for the outcome's copy. Null where they have none.
final class EventAttendeeAddRequested extends EventActionsEvent {
  const EventAttendeeAddRequested(
    this.eventId,
    this.userId,
    this.role, {
    this.name,
  });

  final String eventId;
  final String userId;
  final EventRole role;
  final String? name;

  @override
  List<Object?> get props => [eventId, userId, role, name];
}

/// Remove the roster row [attendeeId] from [eventId] (#510).
final class EventAttendeeRemoveRequested extends EventActionsEvent {
  const EventAttendeeRemoveRequested(
    this.eventId,
    this.attendeeId, {
    this.name,
  });

  final String eventId;
  final String attendeeId;
  final String? name;

  @override
  List<Object?> get props => [eventId, attendeeId, name];
}

/// Set the answer of the roster row [attendeeId] on [eventId] to [status],
/// for someone else (#510).
final class EventAttendeeAnswerRequested extends EventActionsEvent {
  const EventAttendeeAnswerRequested(
    this.eventId,
    this.attendeeId,
    this.status, {
    this.name,
  });

  final String eventId;
  final String attendeeId;
  final EventParticipationStatus status;
  final String? name;

  @override
  List<Object?> get props => [eventId, attendeeId, status, name];
}

/// The screen dropped a write of [action] once its dialog closed, because
/// the event no longer offered it (#502, #655), and nothing was sent. Its
/// banner says the event changed, as a 400 for it would, so a screen reader
/// hears why nothing happened. [statusWrite] says which, for the four that
/// change the event's own status, and [attendeeWrite] and [attendeeName] for
/// a roster write (#510).
final class EventWriteDropped extends EventActionsEvent {
  /// Drops a date write.
  const EventWriteDropped(this.action)
    : statusWrite = null,
      attendeeWrite = null,
      attendeeName = null;

  /// Drops [write], under the action whose grant it needs.
  EventWriteDropped.status(EventStatusWrite write)
    : action = write.action,
      statusWrite = write,
      attendeeWrite = null,
      attendeeName = null;

  /// Drops a roster [write] for the person named [name], if they have one.
  const EventWriteDropped.attendee(EventAttendeeWrite write, {String? name})
    : action = EventAction.manageAttendees,
      statusWrite = null,
      attendeeWrite = write,
      attendeeName = name;

  final EventAction action;
  final EventStatusWrite? statusWrite;
  final EventAttendeeWrite? attendeeWrite;
  final String? attendeeName;

  @override
  List<Object?> get props => [action, statusWrite, attendeeWrite, attendeeName];
}

/// The person closed the last action's banner.
final class EventActionOutcomeDismissed extends EventActionsEvent {
  const EventActionOutcomeDismissed();
}
