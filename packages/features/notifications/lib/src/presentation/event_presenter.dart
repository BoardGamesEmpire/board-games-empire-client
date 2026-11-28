import 'package:flutter/material.dart';
import 'package:notifications/l10n/notifications_localizations.dart';
import 'package:notifications/src/presentation/notification_presentation.dart';
import 'package:notifications/src/presentation/notification_target.dart';
import 'package:notifications/src/presentation/payload_fields.dart';

// The notifications about an event, its RSVPs, its dates, its invites, its
// nominations and its lineup (#504, #475). Every payload carries `eventId`,
// and all but a nomination's outcome carry `eventTitle`. Each function
// returns null when a field its wording or target needs is missing or isn't
// a string, and `presentNotification` then shows a plain row. Event titles,
// game titles and subtitles, people's names and the host's reason go in as
// the server sent them.

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
    quote: nonBlankString(payload, 'reason'),
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

/// `EventAttendeeRemoved`, sent to the person removed: opens the event.
/// Removal takes away only what attending gave them, so they can still see
/// an event of their household, a public one, or one that reaches their
/// friends. Where they can't, the event's page says it can't be found.
NotificationPresentation? presentEventAttendeeRemoved(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final event = _event(payload);
  if (event == null) return null;
  return NotificationPresentation(
    icon: Icons.person_remove_outlined,
    title: l10n.notificationEventAttendeeRemovedTitle(event.title),
    target: EventTarget(event.id),
  );
}

/// `EventRsvpReceived`, sent to the event's hosts and co-hosts: opens the
/// event. A null or blank `attendeeName` is an attendee without an account,
/// whom the row calls "someone without an account", not a guest; one that
/// isn't a string is a malformed payload and gives a plain row.
NotificationPresentation? presentEventRsvpReceived(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final event = _event(payload);
  if (event == null) return null;
  if (isWrongType(payload, 'attendeeName')) return null;
  final attendeeName = nonBlankString(payload, 'attendeeName');
  return NotificationPresentation(
    icon: Icons.rsvp_outlined,
    title: attendeeName == null
        ? l10n.notificationEventRsvpReceivedNoAccountTitle(event.title)
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
  if (isWrongType(payload, 'changedByName')) return null;
  final changedByName = nonBlankString(payload, 'changedByName');
  return NotificationPresentation(
    icon: Icons.edit_calendar_outlined,
    title: changedByName == null
        ? l10n.notificationEventRsvpChangedUnnamedTitle(event.title)
        : l10n.notificationEventRsvpChangedTitle(changedByName, event.title),
    detail: switch (nonBlankString(payload, 'status')) {
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
  final inviterName = nonBlankString(payload, 'inviterName');
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
  final inviteeName = nonBlankString(payload, 'inviteeName');
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
  final inviteeName = nonBlankString(payload, 'inviteeName');
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
/// `Rescheduled`, which share one payload: opens the event on its lineup,
/// on that date. The detail names the date by `occurrenceLabel`, as the
/// server wrote it, and is left out when there is none.
NotificationPresentation? presentEventDateChange(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
  EventDateChange change,
) {
  final event = _event(payload);
  final occurrenceId = nonBlankString(payload, 'occurrenceId');
  if (event == null || occurrenceId == null) return null;
  final label = nonBlankString(payload, 'occurrenceLabel');
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
    target: EventTarget(event.id, tab: _lineupTab, date: occurrenceId),
  );
}

/// `GameNominated`, sent to the event's attendees: opens the event on its
/// nominations, where the game can be voted on. The payload has no subtitle.
NotificationPresentation? presentGameNominated(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final event = _event(payload);
  final gameTitle = nonBlankString(payload, 'nominatedGameTitle');
  if (event == null || gameTitle == null) return null;
  return NotificationPresentation(
    icon: Icons.how_to_vote_outlined,
    title: l10n.notificationGameNominatedTitle(gameTitle, event.title),
    target: EventTarget(event.id, tab: _nominationsTab),
  );
}

/// How a nomination the user made came out.
enum NominationOutcome { approved, rejected, passed, failed, quorumNotMet }

/// `GameNominationApproved`, `Rejected`, `Passed`, `Failed` and
/// `QuorumNotMet`, which share one payload: opens the event on its
/// nominations. The payload names the game and the event's id, not the
/// event's title, so the title names only the game.
NotificationPresentation? presentNominationOutcome(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
  NominationOutcome outcome,
) {
  final eventId = nonBlankString(payload, 'eventId');
  final gameTitle = nonBlankString(payload, 'nominatedGameTitle');
  if (eventId == null || gameTitle == null) return null;
  return NotificationPresentation(
    icon: switch (outcome) {
      NominationOutcome.approved => Icons.check_circle_outline,
      NominationOutcome.rejected => Icons.cancel_outlined,
      NominationOutcome.passed => Icons.thumb_up_outlined,
      NominationOutcome.failed => Icons.thumb_down_outlined,
      NominationOutcome.quorumNotMet => Icons.groups_outlined,
    },
    title: switch (outcome) {
      NominationOutcome.approved =>
        l10n.notificationGameNominationApprovedTitle(
          gameTitle,
        ),
      NominationOutcome.rejected =>
        l10n.notificationGameNominationRejectedTitle(
          gameTitle,
        ),
      NominationOutcome.passed => l10n.notificationGameNominationPassedTitle(
        gameTitle,
      ),
      NominationOutcome.failed => l10n.notificationGameNominationFailedTitle(
        gameTitle,
      ),
      NominationOutcome.quorumNotMet =>
        l10n.notificationGameNominationQuorumNotMetTitle(gameTitle),
    },
    target: EventTarget(eventId, tab: _nominationsTab),
  );
}

/// `GameAddedToEvent`, sent to the event's attendees: opens the event on its
/// lineup. The game's name carries its subtitle when it has one; a subtitle
/// that isn't a string is a malformed payload and gives a plain row.
NotificationPresentation? presentGameAddedToEvent(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final event = _event(payload);
  final gameName = _gameName(
    l10n,
    payload,
    titleKey: 'nominatedGameTitle',
    subtitleKey: 'nominatedGameSubtitle',
  );
  if (event == null || gameName == null) return null;
  return NotificationPresentation(
    icon: Icons.playlist_add_outlined,
    title: l10n.notificationGameAddedToEventTitle(gameName, event.title),
    target: EventTarget(event.id, tab: _lineupTab),
  );
}

/// `GameRemovedFromEvent`, sent to the attendees still coming: opens the
/// event on its lineup, on the date the game was on when `occurrenceId` names
/// one, else the event's own. The `reason` words the row. `TakenOut` doesn't
/// say who did it, as it may be a host, a co-host, a moderator or an owner or
/// admin of the event's household. A reason this version doesn't know gets
/// the generic wording with no detail, because the server adds reasons. A
/// missing or blank `reason`, or a subtitle or `occurrenceId` that isn't a
/// string, is a malformed payload and gives a plain row.
NotificationPresentation? presentGameRemovedFromEvent(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final event = _event(payload);
  final gameName = _gameName(
    l10n,
    payload,
    titleKey: 'gameTitle',
    subtitleKey: 'gameSubtitle',
  );
  final reason = nonBlankString(payload, 'reason');
  if (event == null || gameName == null || reason == null) return null;
  if (isWrongType(payload, 'occurrenceId')) return null;
  return NotificationPresentation(
    icon: Icons.playlist_remove_outlined,
    title: reason == 'TakenOut'
        ? l10n.notificationGameTakenOutOfEventTitle(gameName, event.title)
        : l10n.notificationGameRemovedFromEventTitle(gameName, event.title),
    detail: switch (reason) {
      'SupplierLeft' => l10n.notificationGameRemovedSupplierLeftDetail,
      'NobodyBringing' => l10n.notificationGameRemovedNobodyBringingDetail,
      'RemovedFromCollection' =>
        l10n.notificationGameRemovedFromCollectionDetail,
      _ => null,
    },
    target: EventTarget(
      event.id,
      tab: _lineupTab,
      date: nonBlankString(payload, 'occurrenceId'),
    ),
  );
}

/// The `tab` values of the event screen's Games sub-tabs (#504, #475).
const _nominationsTab = 'nominations';
const _lineupTab = 'lineup';

/// The game's name for a title: [titleKey]'s title, and [subtitleKey]'s
/// subtitle after it when there is one. Null when the title is missing or the
/// subtitle isn't null or a string.
String? _gameName(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload, {
  required String titleKey,
  required String subtitleKey,
}) {
  final title = nonBlankString(payload, titleKey);
  if (title == null || isWrongType(payload, subtitleKey)) return null;
  final subtitle = nonBlankString(payload, subtitleKey);
  return subtitle == null
      ? title
      : l10n.notificationGameNameWithSubtitle(title, subtitle);
}

/// The event every payload here names, or null when it doesn't.
({String id, String title})? _event(Map<String, Object?> payload) {
  final id = nonBlankString(payload, 'eventId');
  final title = nonBlankString(payload, 'eventTitle');
  if (id == null || title == null) return null;
  return (id: id, title: title);
}
