import 'package:flutter/material.dart';
import 'package:models/domain.dart';

import 'package:events/l10n/events_localizations.dart';

// The words for an event's values, where the overview and the detail screen
// show them (#497, #498).
//
// Each enum label is null for `unknown`, a value a newer server sent: the
// caller leaves its line out rather than guess at what it means.

/// The kind of event the host chose.
String? eventTypeLabel(EventsLocalizations l10n, EventType type) =>
    switch (type) {
      EventType.adultsOnly => l10n.eventsTypeAdultsOnly,
      EventType.casualGathering => l10n.eventsTypeCasualGathering,
      EventType.competitivePlay => l10n.eventsTypeCompetitivePlay,
      EventType.familyNight => l10n.eventsTypeFamilyNight,
      EventType.kidFriendly => l10n.eventsTypeKidFriendly,
      EventType.learningSession => l10n.eventsTypeLearningSession,
      EventType.longGameDay => l10n.eventsTypeLongGameDay,
      EventType.mixedAges => l10n.eventsTypeMixedAges,
      EventType.partyGames => l10n.eventsTypePartyGames,
      EventType.strategyNight => l10n.eventsTypeStrategyNight,
      EventType.unknown => null,
    };

/// Where the event stands in its life.
String? eventStatusLabel(EventsLocalizations l10n, EventStatus status) =>
    switch (status) {
      EventStatus.archived => l10n.eventsStatusArchived,
      EventStatus.cancelled => l10n.eventsStatusCancelled,
      EventStatus.completed => l10n.eventsStatusCompleted,
      EventStatus.ongoing => l10n.eventsStatusOngoing,
      EventStatus.planning => l10n.eventsStatusPlanning,
      EventStatus.scheduled => l10n.eventsStatusScheduled,
      EventStatus.unknown => null,
    };

/// Who may see the event.
String? eventReachLabel(EventsLocalizations l10n, Reach reach) =>
    switch (reach) {
      Reach.friends => l10n.eventsReachFriends,
      Reach.friendsOfFriends => l10n.eventsReachFriendsOfFriends,
      Reach.private => l10n.eventsReachPrivate,
      Reach.public => l10n.eventsReachPublic,
      Reach.unknown => null,
    };

/// A role as a noun phrase with its article ("the host", "a guest"), for
/// the viewer's role line, which puts it in a sentence.
String? eventRolePhrase(EventsLocalizations l10n, EventRole role) =>
    switch (role) {
      EventRole.host => l10n.eventsRoleHost,
      EventRole.coHost => l10n.eventsRoleCoHost,
      EventRole.organizer => l10n.eventsRoleOrganizer,
      EventRole.moderator => l10n.eventsRoleModerator,
      EventRole.participant => l10n.eventsRoleParticipant,
      EventRole.guest => l10n.eventsRoleGuest,
      EventRole.spectator => l10n.eventsRoleSpectator,
      EventRole.unknown => null,
    };

/// A role as a label ("Host", "Guest"), beside a name on the roster.
String? eventRoleLabel(EventsLocalizations l10n, EventRole role) =>
    switch (role) {
      EventRole.host => l10n.eventsRoleLabelHost,
      EventRole.coHost => l10n.eventsRoleLabelCoHost,
      EventRole.organizer => l10n.eventsRoleLabelOrganizer,
      EventRole.moderator => l10n.eventsRoleLabelModerator,
      EventRole.participant => l10n.eventsRoleLabelParticipant,
      EventRole.guest => l10n.eventsRoleLabelGuest,
      EventRole.spectator => l10n.eventsRoleLabelSpectator,
      EventRole.unknown => null,
    };

/// Where one of the event's dates stands.
String? occurrenceStatusLabel(
  EventsLocalizations l10n,
  OccurrenceStatus status,
) => switch (status) {
  OccurrenceStatus.proposed => l10n.eventsOccurrenceProposed,
  OccurrenceStatus.confirmed => l10n.eventsOccurrenceConfirmed,
  OccurrenceStatus.declined => l10n.eventsOccurrenceDeclined,
  OccurrenceStatus.cancelled => l10n.eventsOccurrenceCancelled,
  OccurrenceStatus.unknown => null,
};

/// An answer to the invitation: the user's own on a row, and each
/// attendee's on the roster. Null too where there is no answer to show.
String? eventRsvpLabel(
  EventsLocalizations l10n,
  EventParticipationStatus? status,
) => switch (status) {
  EventParticipationStatus.attending => l10n.eventsRsvpAttending,
  EventParticipationStatus.maybe => l10n.eventsRsvpMaybe,
  EventParticipationStatus.notAttending => l10n.eventsRsvpNotAttending,
  EventParticipationStatus.invited => l10n.eventsRsvpInvited,
  EventParticipationStatus.unknown || null => null,
};

/// When [instant] falls, as an event's row says it (#497): the day in
/// device-local time, with the year only when it isn't [now]'s, then the
/// time of day ([eventTimeOfDayLabel]).
///
/// One function for the row and the detail screen's dates (#498), so the
/// two never say the same moment two ways.
String eventWhenLabel(
  BuildContext context,
  DateTime instant, {
  required DateTime now,
}) {
  final l10n = EventsLocalizations.of(context);
  // The server stamps it in UTC; the user goes on their own day.
  final local = instant.toLocal();
  final time = eventTimeOfDayLabel(context, local);
  return local.year == now.toLocal().year
      ? l10n.eventsWhen(local, time)
      : l10n.eventsWhenWithYear(local, time);
}

/// What the dialogs and a date's menu call [occurrence]: its label, else
/// when it starts, as its entry on the detail says it, else that it has no
/// date yet.
String eventDateName(
  BuildContext context,
  EventOccurrence occurrence, {
  required DateTime now,
}) {
  final label = occurrence.label?.trim();
  if (label != null && label.isNotEmpty) return label;
  final start = occurrence.startDate;
  if (start != null) return eventWhenLabel(context, start, now: now);
  return EventsLocalizations.of(context).eventsNoDateYet;
}

/// The device-local time of day of [instant].
///
/// From [MaterialLocalizations.formatTimeOfDay], told the platform's 24-hour
/// setting, rather than from `intl`: `intl` follows the locale alone, so a
/// user who set 24-hour time on a 12-hour locale would get the 12-hour form.
String eventTimeOfDayLabel(BuildContext context, DateTime instant) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(instant.toLocal()),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );
