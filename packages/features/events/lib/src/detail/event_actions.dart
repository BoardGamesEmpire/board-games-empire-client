/// What a viewer may do to an event, by their role on it (#498).
///
/// One table behind every control the event screens offer. The issues that add
/// those controls (#500 to #518) read it rather than each deciding who sees
/// a button, so a role's rights are written down once.
///
/// The table follows the backend's `role-permission.catalog.ts` until
/// BoardGamesEmpire/board-games-empire-backend#911 writes an event role table.
///
/// The server stays the authority and answers 403. The table only decides what
/// the client offers, and a role that changed under an open screen shows the
/// server's refusal.
///
/// Complete has no action, because the backend has no route for it
/// (backend#795). Adding a game directly waits for #518, because the event's
/// policy decides it.
library;

import 'package:models/domain.dart';

/// What a viewer may do to an event, one per action a later issue offers.
enum EventAction {
  /// Change the event's details (#500).
  edit,

  /// Remove the event (#501).
  delete,

  /// Call the whole event off (#502).
  cancel,

  /// Put a cancelled event away (#502). The server also requires the event to
  /// be cancelled already. Gating on that is #502's job, not this table's,
  /// which knows roles and not statuses.
  archive,

  /// Propose another date (#506).
  addDate,

  /// Settle on a proposed date (#506).
  confirmDate,

  /// Turn down a proposed date (#506).
  declineDate,

  /// Call off a confirmed date (#506).
  cancelDate,

  /// Answer whether the viewer is coming (#508).
  rsvp,

  /// Add people to the roster and remove them (#510).
  manageAttendees,

  /// Accept a nominated game (#518).
  approveGame,

  /// Turn down a nominated game (#518).
  rejectGame,

  /// Settle a nomination by its votes (#518).
  resolveNomination,
}

/// The actions [event] offers a viewer holding [eventRole] on it and, on a
/// household event, [householdRole] in its household, as an unmodifiable
/// set: a state compares by it, so nothing may change it after.
///
/// The two roles are independent and their actions add up: a household owner
/// who also attends gets both what the household gives and what attending
/// gives. A household role counts only on a household event, because the
/// server grants it through the event's household.
///
/// A null or unknown role gives nothing. So does an event created offline
/// ([Event.isLocalOnly]): the server doesn't know it yet, so there is nothing
/// for it to authorise.
Set<EventAction> eventActionsFor(
  Event event, {
  EventRole? eventRole,
  HouseholdRole? householdRole,
}) {
  if (event.isLocalOnly) return const {};

  final fromEvent = switch (eventRole) {
    EventRole.host => _host,
    EventRole.coHost => _coHost,
    EventRole.organizer => _organizer,
    EventRole.moderator => _moderator,
    EventRole.participant ||
    EventRole.guest ||
    EventRole.spectator => _attending,
    EventRole.unknown || null => const <EventAction>{},
  };

  final fromHousehold = event.householdId == null
      ? const <EventAction>{}
      : switch (householdRole) {
          HouseholdRole.householdOwner ||
          HouseholdRole.householdAdmin => _householdOwnerOrAdmin,
          HouseholdRole.householdMember ||
          HouseholdRole.householdGuest ||
          HouseholdRole.unknown ||
          null => const <EventAction>{},
        };

  return Set.unmodifiable({...fromEvent, ...fromHousehold});
}

// The sets below are the backend's grants, slug by slug, from
// `role-permission.catalog.ts`. The test asserts each one in full.

/// `EventHost`: every action.
const _host = <EventAction>{
  // `update:event`
  EventAction.edit,
  // `delete:event`, which the catalog's `EVENT_HOST_ONLY` gives the host alone.
  EventAction.delete,
  // `update:event:status:cancel-event`
  EventAction.cancel,
  // `update:event:status:archive-event`, whose condition names the host alone.
  EventAction.archive,
  // `create:event_occurrence`
  EventAction.addDate,
  // `update:event_occurrence:confirm`
  EventAction.confirmDate,
  // `update:event_occurrence:decline`
  EventAction.declineDate,
  // `update:event_occurrence:cancel`
  EventAction.cancelDate,
  // `update:event_attendee:status`, bound to the event rather than the
  // actor's own row, so it covers the host's row too. A participant, guest or
  // spectator holds only the `:self` variant.
  EventAction.rsvp,
  // `manage:event_attendee`
  EventAction.manageAttendees,
  // `update:event_game_nomination:approve`
  EventAction.approveGame,
  // `update:event_game_nomination:reject`
  EventAction.rejectGame,
  // `update:event_game_nomination:resolve`
  EventAction.resolveNomination,
};

/// `EventCoHost`: every action except `delete` and `archive`.
///
/// The role catalog derives the co-host's list from the host's minus
/// `EVENT_HOST_ONLY`, which is `delete:event` alone, so it assigns the co-host
/// `update:event:status:archive-event`. That permission's condition names
/// `EventHost` alone, so a co-host's archive is always refused. The table
/// follows the condition and offers what the server will grant. The condition
/// on `update:event:status:cancel-event` names co-hosts too, so they keep
/// `cancel`.
const _coHost = <EventAction>{
  EventAction.edit,
  EventAction.cancel,
  EventAction.addDate,
  EventAction.confirmDate,
  EventAction.declineDate,
  EventAction.cancelDate,
  EventAction.rsvp,
  EventAction.manageAttendees,
  EventAction.approveGame,
  EventAction.rejectGame,
  EventAction.resolveNomination,
};

/// `EventOrganizer`.
const _organizer = <EventAction>{
  // `update:event`
  EventAction.edit,
  // `create:event_occurrence`. Not the confirm, decline or cancel slugs, which
  // the organizer's list leaves out.
  EventAction.addDate,
  // `update:event_attendee:status`
  EventAction.rsvp,
  // `create:event_attendee:attending-role` and
  // `delete:event_attendee:attending-role`: the organizer adds and removes
  // those who attend, without the appointing of hosts and moderators that
  // `manage:event_attendee` carries (#539).
  EventAction.manageAttendees,
};

/// `EventModerator`.
const _moderator = <EventAction>{
  // `update:event`
  EventAction.edit,
  // `update:event_occurrence:cancel`
  EventAction.cancelDate,
  // `update:event_attendee:status`
  EventAction.rsvp,
  // `create:event_attendee:attending-role` and
  // `delete:event_attendee:attending-role`, as for the organizer.
  EventAction.manageAttendees,
  // `update:event_game_nomination:resolve`
  EventAction.resolveNomination,
};

/// `EventParticipant`, `EventGuest` and `EventSpectator`: they answer for
/// themselves and nothing else.
const _attending = <EventAction>{
  // `update:event_attendee:status:self`
  EventAction.rsvp,
};

/// `HouseholdOwner` and `HouseholdAdmin` on the household's own events. Every
/// slug is the event role's with a `:household` suffix, bound through the
/// event's household.
///
/// No `rsvp`: answering is for someone on the roster, and an owner who attends
/// takes it from their event role. No `delete`, because an owner or admin
/// deletes only an event they host (#168). No `cancel` or `archive` either:
/// the household's list holds no event status slug.
const _householdOwnerOrAdmin = <EventAction>{
  // `update:event:household`
  EventAction.edit,
  // `create:event_occurrence:household`
  EventAction.addDate,
  // `update:event_occurrence:confirm:household`
  EventAction.confirmDate,
  // `update:event_occurrence:decline:household`
  EventAction.declineDate,
  // `update:event_occurrence:cancel:household`
  EventAction.cancelDate,
  // `manage:event_attendee:household`
  EventAction.manageAttendees,
  // `update:event_game_nomination:resolve:household`. Approving and rejecting
  // a nomination have no household variant.
  EventAction.resolveNomination,
};
