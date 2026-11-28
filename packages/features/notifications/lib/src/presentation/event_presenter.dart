import 'package:flutter/material.dart';
import 'package:notifications/l10n/notifications_localizations.dart';
import 'package:notifications/src/presentation/notification_presentation.dart';
import 'package:notifications/src/presentation/notification_target.dart';

// The notifications about an event, its RSVPs, its dates and its invites
// (#504, #475). Every payload carries `eventId` and `eventTitle`. Each
// function returns null when a field its wording or target needs is missing
// or isn't a string, and `presentNotification` then shows a plain row. Event
// titles, people's names and the host's reason go in as the server sent
// them.

/// `EventCreated`, sent to a household's members: opens the event.
NotificationPresentation? presentEventCreated(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final event = _event(payload);
  if (event == null) return null;
  return NotificationPresentation(
    icon: Icons.event_outlined,
    title: l10n.notificationEventCreatedTitle(event.title),
    target: EventTarget(event.id),
  );
}

/// `EventReopened`, sent to the event's attendees: opens the event.
NotificationPresentation? presentEventReopened(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final event = _event(payload);
  if (event == null) return null;
  return NotificationPresentation(
    icon: Icons.event_repeat_outlined,
    title: l10n.notificationEventReopenedTitle(event.title),
    target: EventTarget(event.id),
  );
}

/// `EventCancelled`, sent to the event's attendees: opens the event. The
/// host's reason, when they gave one, is the quote.
NotificationPresentation? presentEventCancelled(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final event = _event(payload);
  if (event == null) return null;
  return NotificationPresentation(
    icon: Icons.event_busy_outlined,
    title: l10n.notificationEventCancelledTitle(event.title),
    quote: _string(payload, 'reason'),
    target: EventTarget(event.id),
  );
}

/// `EventDeleted`, sent to the event's attendees: the event is gone, so the
/// row opens nothing and the title says what happened.
NotificationPresentation? presentEventDeleted(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final event = _event(payload);
  if (event == null) return null;
  return NotificationPresentation(
    icon: Icons.delete_outline,
    title: l10n.notificationEventDeletedTitle(event.title),
  );
}

/// `EventAttendeeRemoved`, sent to the person removed: the event isn't theirs
/// to open any more, so the row opens nothing.
NotificationPresentation? presentEventAttendeeRemoved(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final event = _event(payload);
  if (event == null) return null;
  return NotificationPresentation(
    icon: Icons.person_remove_outlined,
    title: l10n.notificationEventAttendeeRemovedTitle(event.title),
  );
}

/// `EventRsvpReceived`, sent to the event's hosts and co-hosts: opens the
/// event. A null or blank `attendeeName` is an attendee without an account,
/// whom the row calls a guest; one that isn't a string is a malformed payload
/// and gives a plain row.
NotificationPresentation? presentEventRsvpReceived(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final event = _event(payload);
  if (event == null) return null;
  if (_isWrongType(payload, 'attendeeName')) return null;
  final attendeeName = _string(payload, 'attendeeName');
  return NotificationPresentation(
    icon: Icons.rsvp_outlined,
    title: attendeeName == null
        ? l10n.notificationEventRsvpReceivedGuestTitle(event.title)
        : l10n.notificationEventRsvpReceivedTitle(attendeeName, event.title),
    target: EventTarget(event.id),
  );
}

/// `EventRsvpChanged`, sent to an attendee whose RSVP someone else changed:
/// opens the event. A null or blank `changedByName` is a change that didn't
/// come from a user; one that isn't a string is a malformed payload and gives
/// a plain row. The detail gives the new answer, and is left out for a status
/// this version doesn't know.
NotificationPresentation? presentEventRsvpChanged(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final event = _event(payload);
  if (event == null) return null;
  if (_isWrongType(payload, 'changedByName')) return null;
  final changedByName = _string(payload, 'changedByName');
  return NotificationPresentation(
    icon: Icons.edit_calendar_outlined,
    title: changedByName == null
        ? l10n.notificationEventRsvpChangedUnnamedTitle(event.title)
        : l10n.notificationEventRsvpChangedTitle(changedByName, event.title),
    detail: switch (_string(payload, 'status')) {
      'Attending' => l10n.notificationEventRsvpNowAttendingDetail,
      'Maybe' => l10n.notificationEventRsvpNowMaybeDetail,
      'NotAttending' => l10n.notificationEventRsvpNowNotAttendingDetail,
      'Invited' => l10n.notificationEventRsvpNowInvitedDetail,
      _ => null,
    },
    target: EventTarget(event.id),
  );
}

/// `EventInviteReceived`, sent to the invitee. It means an invite is waiting,
/// not that the user is on the event, and the app can't show an event invite
/// yet, so the row opens nothing and the user can only mark it read (#504,
/// #1133).
NotificationPresentation? presentEventInviteReceived(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final event = _event(payload);
  final inviterName = _string(payload, 'inviterName');
  if (event == null || inviterName == null) return null;
  return NotificationPresentation(
    icon: Icons.mail_outline,
    title: l10n.notificationEventInviteReceivedTitle(inviterName, event.title),
  );
}

/// `EventInviteAccepted`, sent to the inviter: opens the event, which they
/// can see.
NotificationPresentation? presentEventInviteAccepted(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final event = _event(payload);
  final inviteeName = _string(payload, 'inviteeName');
  if (event == null || inviteeName == null) return null;
  return NotificationPresentation(
    icon: Icons.event_available_outlined,
    title: l10n.notificationEventInviteAcceptedTitle(inviteeName, event.title),
    target: EventTarget(event.id),
  );
}

/// `EventInviteDeclined`, sent to the inviter: opens the event, which they
/// can see.
NotificationPresentation? presentEventInviteDeclined(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final event = _event(payload);
  final inviteeName = _string(payload, 'inviteeName');
  if (event == null || inviteeName == null) return null;
  return NotificationPresentation(
    icon: Icons.person_off_outlined,
    title: l10n.notificationEventInviteDeclinedTitle(inviteeName, event.title),
    target: EventTarget(event.id),
  );
}

/// What happened to one of an event's dates.
enum EventDateChange { proposed, confirmed, declined, canceled, rescheduled }

/// `EventOccurrenceProposed`, `Confirmed`, `Declined`, `Canceled` and
/// `Rescheduled`, which share one payload: opens the event on its Games tab,
/// on that date. The detail names the date by `occurrenceLabel`, as the
/// server wrote it, and is left out when there is none.
NotificationPresentation? presentEventDateChange(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
  EventDateChange change,
) {
  final event = _event(payload);
  final occurrenceId = _string(payload, 'occurrenceId');
  if (event == null || occurrenceId == null) return null;
  final label = _string(payload, 'occurrenceLabel');
  return NotificationPresentation(
    icon: switch (change) {
      EventDateChange.proposed => Icons.event_note_outlined,
      EventDateChange.confirmed => Icons.event_available_outlined,
      EventDateChange.declined => Icons.block_outlined,
      EventDateChange.canceled => Icons.event_busy_outlined,
      EventDateChange.rescheduled => Icons.update,
    },
    title: switch (change) {
      EventDateChange.proposed => l10n.notificationEventOccurrenceProposedTitle(
        event.title,
      ),
      EventDateChange.confirmed =>
        l10n.notificationEventOccurrenceConfirmedTitle(event.title),
      EventDateChange.declined => l10n.notificationEventOccurrenceDeclinedTitle(
        event.title,
      ),
      EventDateChange.canceled => l10n.notificationEventOccurrenceCanceledTitle(
        event.title,
      ),
      EventDateChange.rescheduled =>
        l10n.notificationEventOccurrenceRescheduledTitle(event.title),
    },
    detail: label == null
        ? null
        : l10n.notificationEventOccurrenceDetail(label),
    target: EventTarget(event.id, tab: 'games', date: occurrenceId),
  );
}

/// Whether [payload]'s [key] holds something other than null or a string: a
/// payload the server wouldn't send, which is a plain row, not the wording for
/// a null.
bool _isWrongType(Map<String, Object?> payload, String key) {
  final value = payload[key];
  return value != null && value is! String;
}

/// The event every payload here names, or null when it doesn't.
({String id, String title})? _event(Map<String, Object?> payload) {
  final id = _string(payload, 'eventId');
  final title = _string(payload, 'eventTitle');
  if (id == null || title == null) return null;
  return (id: id, title: title);
}

/// [payload]'s [key] when it holds a string with more than whitespace in it,
/// else null.
String? _string(Map<String, Object?> payload, String key) {
  final value = payload[key];
  return value is String && value.trim().isNotEmpty ? value : null;
}
