import 'package:network_interface/network_interface.dart';

import 'package:household/l10n/household_localizations.dart';

import '../bloc/household_member_actions_state.dart';
import 'send_member_request.dart';

/// What to tell the person about [failure], a request to leave the household
/// that did not go through (#479).
///
/// Worded from the result and the status alone. The server's error bodies
/// carry no stable code yet
/// (BoardGamesEmpire/board-games-empire-backend#822), and their own
/// `message` is never shown: the server translates it, and it may not be in
/// the app's language.
///
/// A 400 is the only refusal the route documents, and it says the person is
/// the household's last owner.
String leaveFailureMessage(
  HouseholdLocalizations l10n,
  MemberRequestOutcome failure,
) => switch (failure) {
  (result: HouseholdMemberActionResult.gone, error: _) =>
    l10n.householdLeaveGone,
  (
    result: HouseholdMemberActionResult.refused,
    error: HouseholdMemberRefusedException(statusCode: 400),
  ) =>
    l10n.householdLeaveErrorLastOwner,
  (result: HouseholdMemberActionResult.refused, error: _) =>
    l10n.householdMemberErrorRejected,
  (
    result: HouseholdMemberActionResult.failed,
    error: HouseholdMemberTransientException(),
  ) =>
    l10n.householdMemberErrorOffline,
  // Anything else failed in a way the app could not read.
  _ => l10n.householdMemberErrorUnexpected,
};
