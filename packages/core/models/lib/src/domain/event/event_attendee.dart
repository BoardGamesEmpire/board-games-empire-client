import 'package:freezed_annotation/freezed_annotation.dart';

import '../user/person_name.dart';
import 'event_participation_status.dart';
import 'event_role.dart';

part 'event_attendee.freezed.dart';

/// One person on an event's roster: an account holder, or a guest who has none
/// (#496).
///
/// ## What is deliberately not here
///
/// **`guestEmail`.** The server keeps a guest's email address on the row, and
/// it is out of scope for the data layer (#496), so the type has no field for
/// it.
@freezed
abstract class EventAttendee with _$EventAttendee {
  const EventAttendee._();

  const factory EventAttendee({
    required String id,
    required String eventId,

    /// The attendee's account. Null for a guest, who has none.
    String? userId,

    /// A guest's name, as it was given when they were added. A guest has no
    /// account to take one from.
    String? guestName,

    /// The attendee's account name, display name and avatar, as the roster
    /// embeds them. All three are null for a guest, and [displayName] and
    /// [avatarUrl] are also null for an account that has not set them.
    String? username,
    String? displayName,
    String? avatarUrl,

    /// A free-text note, typically left with an answer to the invitation.
    String? notes,
    required EventParticipationStatus status,

    /// The attendee's role. Null when the server returns no role binding. A
    /// role name this client does not know reads as [EventRole.unknown].
    EventRole? role,

    /// When the attendee last answered yes or no. Null until they have.
    DateTime? rsvpDate,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _EventAttendee;

  /// True when the attendee has no account ([userId] is null), so the roster
  /// can only name them by [guestName].
  bool get isGuest => userId == null;

  /// The name to show for this attendee: [displayName], else [username], else
  /// [guestName]. A guest has no account to take either of the first two
  /// from, only the name given when they were added. Null where none holds
  /// anything.
  String? get name =>
      personName(displayName: displayName, username: username) ??
      personName(username: guestName);
}
