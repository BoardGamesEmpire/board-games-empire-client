import 'package:network_interface/network_interface.dart';

import 'package:household/l10n/household_localizations.dart';

import '../bloc/household_member_actions_state.dart';
import '../permissions/household_actions.dart';

/// What to tell the person about [outcome], a role change or removal
/// (#480).
///
/// A refusal is worded from its status alone. The server's error bodies
/// carry no stable code yet
/// (BoardGamesEmpire/board-games-empire-backend#822), and their own
/// `message` is never shown: the server translates it, and it may not be in
/// the app's language.
///
/// Making someone owner has no route yet (#478), so nothing reports it. It
/// reads as a role change until #478 gives it its own copy.
String memberActionMessage(
  HouseholdLocalizations l10n,
  HouseholdMemberOutcome outcome,
) => switch (outcome.result) {
  HouseholdMemberActionResult.done => switch (outcome.action) {
    HouseholdMemberAction.changeRole ||
    HouseholdMemberAction.makeOwner => l10n.householdMemberDoneRole,
    HouseholdMemberAction.remove => l10n.householdMemberDoneRemove,
  },
  HouseholdMemberActionResult.gone => switch (outcome.action) {
    HouseholdMemberAction.changeRole ||
    HouseholdMemberAction.makeOwner => l10n.householdMemberGoneRole,
    HouseholdMemberAction.remove => l10n.householdMemberGoneRemove,
  },
  HouseholdMemberActionResult.refused => switch (outcome.error) {
    // The viewer's own role may have changed on another device.
    HouseholdMemberRefusedException(statusCode: 403) =>
      l10n.householdMemberErrorRoleChanged,
    // A 400 or 409: the server would not take the change, for a reason its
    // body does not name in a way the client can read.
    _ => l10n.householdMemberErrorRejected,
  },
  HouseholdMemberActionResult.failed => switch (outcome.error) {
    HouseholdMemberTransientException() => l10n.householdMemberErrorOffline,
    _ => l10n.householdMemberErrorUnexpected,
  },
};
