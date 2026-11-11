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
/// Complete has no action, because the server works Completed out from the
/// confirmed dates (backend#795). `cancel` covers cancel and reopen, and
/// `archive` covers archive and unarchive, because the server binds each pair
/// to one grant. Which of the pair a status offers is the detail's (#502), not
/// this table's, which knows roles and not statuses. `offerGame` covers
/// offering a game from a collection and taking it back (#516), because every
/// role that may add to an offered-games list may remove from it. Adding a
/// game directly has no action, because the event's policy decides it (#518).
/// `nominateGame` covers nominating a game and withdrawing your own
/// nomination, as `offerGame` covers offering and taking back, and `voteGame`
/// covers voting on one (#517).
///
/// A guest holds neither, though a participant holds both. The catalog gives
/// `create:event_game_nomination`, `create:event_game_vote` and
/// `update:event_game_nomination:withdraw` to the host (`:217-226`), the
/// co-host (the host's list less the host-only slugs, `:490`) and the
/// participant (`:533-556`), and leaves them off the guest's, so the two roles
/// no longer share a set. An organizer, moderator, spectator, household owner
/// and household admin hold none of them either.
library;

import 'package:models/domain.dart';

/// What a viewer may do to an event, one per action a later issue offers.
enum EventAction {
  /// Change the event's details (#500).
  edit,

  /// Remove the event (#501).
  delete,

  /// Call the event off, and reopen it.
  cancel,

  /// Put an ended or cancelled event away, and take it out again. Which a
  /// status offers is the detail's (#502).
  archive,

  /// Propose another date (#506).
  addDate,

  /// Change a date's time, label or place (#506).
  editDate,

  /// Settle on a proposed date (#506).
  confirmDate,

  /// Turn down a proposed date (#506).
  declineDate,

  /// Call off a confirmed date (#506).
  cancelDate,

  /// Take a date off the event (#506). The household roles don't hold it: an
  /// owner or admin who doesn't host asks for a removal instead (#513).
  removeDate,

  /// Answer whether the viewer can make a proposed date (#507).
  voteAvailability,

  /// Answer whether the viewer is coming (#508).
  rsvp,

  /// Add people to the roster and remove them (#510). Held wherever
  /// [attendeeReachFor] gives more than [AttendeeReach.none]: the role sets
  /// below leave it out, so the reach is its one source.
  manageAttendees,

  /// Accept a nominated game (#518).
  approveGame,

  /// Turn down a nominated game (#518).
  rejectGame,

  /// Settle a nomination by its votes (#518).
  resolveNomination,

  /// Offer a game from your collection to the event, and take it back (#516).
  /// One action for both, because every role that may add to an offered-games
  /// list may remove from it. A host, co-host, organizer, participant or guest
  /// manages their own list, a moderator any list, and a household owner or
  /// admin any list on a household event. A spectator may not. An owner or
  /// admin still needs their own row on the roster to have a list to add to,
  /// which `offerGamesGate` asks for.
  offerGame,

  /// Nominate a game for the event's dates, and withdraw your own nomination
  /// (#517). One action for both, because every role that may nominate may
  /// withdraw. Held by the host, co-host and participant only: not by a guest,
  /// organizer, moderator, spectator, or household owner or admin.
  nominateGame,

  /// Vote on a nominated game (#517). Held by the roles that hold
  /// [nominateGame].
  voteGame,
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
    EventRole.participant => _participant,
    EventRole.guest => _guest,
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

  // The roster's grants are written once, in [attendeeReachFor], so the
  // action and the reach can't disagree.
  final manages =
      attendeeReachFor(
        event,
        eventRole: eventRole,
        householdRole: householdRole,
      ) !=
      AttendeeReach.none;

  return Set.unmodifiable({
    ...fromEvent,
    ...fromHousehold,
    if (manages) EventAction.manageAttendees,
  });
}

/// How far a viewer reaches over other people's roster rows (#510).
enum AttendeeReach {
  /// No attendee writes.
  none,

  /// `create:event_attendee:attending-role` and
  /// `delete:event_attendee:attending-role`: an organizer or moderator gives,
  /// and removes, Participant, Guest and Spectator only.
  attendingRoles,

  /// `manage:event_attendee` and its `:household` variant: the host, a
  /// co-host, and a household owner or admin on a household event.
  allRoles,
}

/// The wider of what [eventRole] and, on a household event, [householdRole]
/// give: `manage:event_attendee` (host, co-host) and
/// `manage:event_attendee:household` (household owner, admin) reach
/// [AttendeeReach.allRoles]; the `:attending-role` slugs (organizer,
/// moderator) reach [AttendeeReach.attendingRoles].
///
/// [AttendeeReach.none] for a local-only event, as [eventActionsFor] is.
AttendeeReach attendeeReachFor(
  Event event, {
  EventRole? eventRole,
  HouseholdRole? householdRole,
}) {
  if (event.isLocalOnly) return AttendeeReach.none;

  final fromEvent = switch (eventRole) {
    EventRole.host || EventRole.coHost => AttendeeReach.allRoles,
    EventRole.organizer || EventRole.moderator => AttendeeReach.attendingRoles,
    EventRole.participant ||
    EventRole.guest ||
    EventRole.spectator ||
    EventRole.unknown ||
    null => AttendeeReach.none,
  };

  final fromHousehold = event.householdId == null
      ? AttendeeReach.none
      : switch (householdRole) {
          HouseholdRole.householdOwner ||
          HouseholdRole.householdAdmin => AttendeeReach.allRoles,
          HouseholdRole.householdMember ||
          HouseholdRole.householdGuest ||
          HouseholdRole.unknown ||
          null => AttendeeReach.none,
        };

  // The enum runs narrowest to widest.
  return fromEvent.index >= fromHousehold.index ? fromEvent : fromHousehold;
}

const _attendingRoles = <EventRole>[
  EventRole.participant,
  EventRole.guest,
  EventRole.spectator,
];

const _allAssignableRoles = <EventRole>[
  ..._attendingRoles,
  EventRole.coHost,
  EventRole.organizer,
  EventRole.moderator,
];

/// The roles [reach] may give on an add (`create:event_attendee` under
/// `manage:event_attendee`, or `create:event_attendee:attending-role`), in
/// this order: participant, guest, spectator, then, for
/// [AttendeeReach.allRoles], coHost, organizer, moderator. Never host or
/// unknown. Unmodifiable.
List<EventRole> assignableEventRoles(AttendeeReach reach) => switch (reach) {
  AttendeeReach.none => const <EventRole>[],
  AttendeeReach.attendingRoles => _attendingRoles,
  AttendeeReach.allRoles => _allAssignableRoles,
};

/// Whether [reach] may remove [row] (`delete:event_attendee`, or
/// `delete:event_attendee:attending-role`). Never the host's row, and never
/// the viewer's own ([viewerAttendeeId]). A row whose role is null or
/// unknown is not removable under any reach, because it can't be shown not to
/// be the host's. Under [AttendeeReach.attendingRoles], only a participant's,
/// guest's or spectator's row.
bool canRemoveAttendee(
  AttendeeReach reach,
  EventAttendee row, {
  required String? viewerAttendeeId,
}) {
  if (row.id == viewerAttendeeId) return false;
  final role = row.role;
  if (role == EventRole.host) return false;
  return switch (reach) {
    AttendeeReach.none => false,
    AttendeeReach.attendingRoles => _attendingRoles.contains(role),
    AttendeeReach.allRoles => role != null && role != EventRole.unknown,
  };
}

/// Whether [reach] may set [row]'s answer (`update:event_attendee:status`,
/// bound to the event rather than the actor's own row): any reach but
/// [AttendeeReach.none], on any row but the viewer's own, which their chips
/// answer (#508).
bool canSetAnswerFor(
  AttendeeReach reach,
  EventAttendee row, {
  required String? viewerAttendeeId,
}) => reach != AttendeeReach.none && row.id != viewerAttendeeId;

// The sets below are the backend's grants, slug by slug, from
// `role-permission.catalog.ts`, but for the roster's, which
// [attendeeReachFor] holds. The test asserts each role's actions in full.

/// `EventHost`: every action.
const _host = <EventAction>{
  // `update:event`
  EventAction.edit,
  // `delete:event`, which the catalog's `EVENT_HOST_ONLY` gives the host alone.
  EventAction.delete,
  // `update:event:cancel`
  EventAction.cancel,
  // `update:event:archive`
  EventAction.archive,
  // `create:event_occurrence`
  EventAction.addDate,
  // `update:event_occurrence`
  EventAction.editDate,
  // `update:event_occurrence:confirm`
  EventAction.confirmDate,
  // `update:event_occurrence:decline`
  EventAction.declineDate,
  // `update:event_occurrence:cancel`
  EventAction.cancelDate,
  // `delete:event_occurrence`
  EventAction.removeDate,
  // `create:event_availability_vote`
  EventAction.voteAvailability,
  // `update:event_attendee:status`, bound to the event rather than the
  // actor's own row, so it covers the host's row too. A participant, guest or
  // spectator holds only the `:self` variant.
  EventAction.rsvp,
  // `update:event_game_nomination:approve`
  EventAction.approveGame,
  // `update:event_game_nomination:reject`
  EventAction.rejectGame,
  // `update:event_game_nomination:resolve`
  EventAction.resolveNomination,
  // `create:attendee_game_list` and `delete:attendee_game_list`
  EventAction.offerGame,
  // `create:event_game_nomination` and `update:event_game_nomination:withdraw`
  EventAction.nominateGame,
  // `create:event_game_vote`
  EventAction.voteGame,
};

/// `EventCoHost`: every action except `delete`, which the catalog gives the
/// host alone.
const _coHost = <EventAction>{
  EventAction.edit,
  // `update:event:cancel` and `update:event:archive`
  EventAction.cancel,
  EventAction.archive,
  EventAction.addDate,
  EventAction.editDate,
  EventAction.confirmDate,
  EventAction.declineDate,
  EventAction.cancelDate,
  EventAction.removeDate,
  EventAction.voteAvailability,
  EventAction.rsvp,
  EventAction.approveGame,
  EventAction.rejectGame,
  EventAction.resolveNomination,
  // `create:attendee_game_list` and `delete:attendee_game_list`
  EventAction.offerGame,
  // `create:event_game_nomination` and `update:event_game_nomination:withdraw`
  EventAction.nominateGame,
  // `create:event_game_vote`
  EventAction.voteGame,
};

/// `EventOrganizer`.
const _organizer = <EventAction>{
  // `update:event`
  EventAction.edit,
  // `create:event_occurrence`. Not the confirm, decline or cancel slugs, which
  // the organizer's list leaves out.
  EventAction.addDate,
  // `update:event_occurrence`
  EventAction.editDate,
  // `create:event_availability_vote`
  EventAction.voteAvailability,
  // `update:event_attendee:status`
  EventAction.rsvp,
  // `create:attendee_game_list` and `delete:attendee_game_list`
  EventAction.offerGame,
};

/// `EventModerator`.
const _moderator = <EventAction>{
  // `update:event`
  EventAction.edit,
  // `update:event_occurrence`
  EventAction.editDate,
  // `update:event_occurrence:cancel`
  EventAction.cancelDate,
  // `update:event_attendee:status`
  EventAction.rsvp,
  // `update:event_game_nomination:resolve`
  EventAction.resolveNomination,
  // `manage:attendee_game_list`
  EventAction.offerGame,
};

/// `EventParticipant`: the guest's set, and nominates and votes on games.
const _participant = <EventAction>{
  ..._guest,
  // `create:event_game_nomination` and `update:event_game_nomination:withdraw`
  EventAction.nominateGame,
  // `create:event_game_vote`
  EventAction.voteGame,
};

/// `EventGuest`: answers for themselves, to the invitation and on the proposed
/// dates, and offers games to the event. No nominating or voting on games: the
/// catalog leaves those slugs off the guest's list.
const _guest = <EventAction>{
  // `update:event_attendee:status:self`
  EventAction.rsvp,
  // `create:event_availability_vote`
  EventAction.voteAvailability,
  // `create:attendee_game_list` and `delete:attendee_game_list`
  EventAction.offerGame,
};

/// `EventSpectator`: answers for themselves, but has no vote on a date.
const _attending = <EventAction>{
  // `update:event_attendee:status:self`
  EventAction.rsvp,
};

/// `HouseholdOwner` and `HouseholdAdmin` on the household's own events. Every
/// slug is the event role's with a `:household` suffix, bound through the
/// event's household.
///
/// No `rsvp` or `voteAvailability`: answering is for someone on the roster,
/// and a vote is bound to the voter's own roster row, so an owner who attends
/// takes both from their event role. No `removeDate`, which has no household
/// variant (an owner or admin asks for a removal instead, #513). No
/// `delete`, because an owner or admin deletes only an event they host
/// (#168). No `archive`: of the event status slugs, the household's list
/// holds only `update:event:cancel:household`.
const _householdOwnerOrAdmin = <EventAction>{
  // `update:event:household`
  EventAction.edit,
  // `update:event:cancel:household`
  EventAction.cancel,
  // `create:event_occurrence:household`
  EventAction.addDate,
  // `update:event_occurrence:household`
  EventAction.editDate,
  // `update:event_occurrence:confirm:household`
  EventAction.confirmDate,
  // `update:event_occurrence:decline:household`
  EventAction.declineDate,
  // `update:event_occurrence:cancel:household`
  EventAction.cancelDate,
  // `update:event_game_nomination:resolve:household`. Approving and rejecting
  // a nomination have no household variant.
  EventAction.resolveNomination,
  // `manage:attendee_game_list:household`
  EventAction.offerGame,
};
