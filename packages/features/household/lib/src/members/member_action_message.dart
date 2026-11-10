import 'package:household/l10n/household_localizations.dart';
import 'package:household/src/bloc/household_member_actions_state.dart';
import 'package:household/src/permissions/household_actions.dart';
import 'package:network_interface/network_interface.dart';

/// What to tell the person about [outcome], a role change, removal or
/// ownership transfer (#480, #478).
///
/// A refusal is worded from its status alone. The server's error bodies
/// carry no stable code yet
/// (BoardGamesEmpire/board-games-empire-backend#822), and their own
/// `message` is never shown: the server translates it, and it may not be in
/// the app's language.
String memberActionMessage(
  HouseholdLocalizations l10n,
  HouseholdMemberOutcome outcome,
) => switch (outcome.result) {
  HouseholdMemberActionResult.done => switch (outcome.action) {
    HouseholdMemberAction.changeRole => l10n.householdMemberDoneRole,
    HouseholdMemberAction.makeOwner => l10n.householdMemberDoneOwner,
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
    // The target already owns the household, or is the sender.
    HouseholdMemberRefusedException(statusCode: 400)
        when outcome.action == HouseholdMemberAction.makeOwner =>
      l10n.householdMemberErrorAlreadyOwner,
    // A 400 or 409: the server would not take the change, for a reason its
    // body does not name in a way the client can read.
    _ => l10n.householdMemberErrorRejected,
  },
  HouseholdMemberActionResult.failed => switch (outcome.error) {
    HouseholdMemberTransientException() => l10n.householdMemberErrorOffline,
    _ => l10n.householdMemberErrorUnexpected,
  },
};
