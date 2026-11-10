import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/event/event_attendee.dart';
import 'package:models/src/domain/event/event_participation_status.dart';
import 'package:models/src/domain/event/event_role.dart';

part 'event_attendance.freezed.dart';

/// The current user's own answer on an event, as the list read carries it
/// (#667): their attendee id, status, role and RSVP date, and nothing else.
///
/// It is smaller than an [EventAttendee] on purpose. A list row has no event
/// id, creation time or update time for the attendee, and filling them in with
/// made-up values would give a reader data it cannot trust. The detail read's
/// roster keeps the full [EventAttendee].
@freezed
abstract class EventAttendance with _$EventAttendance {
  const factory EventAttendance({
    required String attendeeId,
    required EventParticipationStatus status,

    /// Null when the server returns no role for the attendee.
    EventRole? role,

    /// When the attendee last answered yes or no. Null until they have.
    DateTime? rsvpDate,
  }) = _EventAttendance;

  /// The part of a roster row that a list row carries.
  factory EventAttendance.fromAttendee(EventAttendee attendee) =>
      EventAttendance(
        attendeeId: attendee.id,
        status: attendee.status,
        role: attendee.role,
        rsvpDate: attendee.rsvpDate,
      );
}
