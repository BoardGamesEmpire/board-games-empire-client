import 'package:network_interface/network_interface.dart';

import 'package:household/l10n/household_localizations.dart';

/// Something a person does with an invite, for wording its failure.
enum HouseholdInviteAction { send, accept, decline, withdraw, revoke, approve }

/// What to tell the person when [action] failed with [error] (#455).
///
/// Worded from the status alone, and from a 402's quota. The server's error
/// bodies carry no stable code yet
/// (BoardGamesEmpire/board-games-empire-backend#822), so where one status
/// has several causes the message names each of them. The body's own
/// `message` is never shown: the server translates it, and it may not be in
/// the app's language.
String inviteRefusalMessage(
  HouseholdLocalizations l10n,
  HouseholdInviteAction action,
  Object error,
) => switch (error) {
  HouseholdInviteTransientException() => l10n.inviteErrorOffline,
  HouseholdInviteRefusedException(:final statusCode, :final quota) => _refusal(
    l10n,
    action,
    statusCode!,
    quota,
  ),
  _ => l10n.inviteErrorUnexpected,
};

String _refusal(
  HouseholdLocalizations l10n,
  HouseholdInviteAction action,
  int status,
  InviteQuota? quota,
) {
  const answers = {HouseholdInviteAction.accept, HouseholdInviteAction.decline};
  const settles = {
    HouseholdInviteAction.decline,
    HouseholdInviteAction.withdraw,
    HouseholdInviteAction.revoke,
    HouseholdInviteAction.approve,
  };
  // Withdraw is left out: the server lets an inviter withdraw whatever
  // their role, so its 403 is never a role that changed. It goes only to
  // the invitee, or to a caller not signed in as themself, and no list
  // offers a withdraw to either.
  const manages = {HouseholdInviteAction.revoke, HouseholdInviteAction.approve};

  return switch (status) {
    410 => l10n.inviteErrorExpired,
    // A send names no invite: its 404 is the household, or the person
    // picked from search no longer having an account.
    404 when action == HouseholdInviteAction.send => l10n.inviteSendErrorGone,
    404 => l10n.inviteErrorGone,
    402 => _quota(l10n, quota),
    400 when action == HouseholdInviteAction.send =>
      l10n.inviteSendErrorInvalid,
    403 when action == HouseholdInviteAction.send =>
      l10n.inviteSendErrorRefused,
    409 when action == HouseholdInviteAction.send =>
      l10n.inviteSendErrorConflict,
    403 when answers.contains(action) => l10n.inviteAnswerErrorNotYours,
    409 when action == HouseholdInviteAction.accept =>
      l10n.inviteAcceptErrorConflict,
    409 when settles.contains(action) => l10n.inviteErrorAlreadySettled,
    403 when manages.contains(action) => l10n.inviteErrorRoleChanged,
    _ => l10n.inviteErrorUnexpected,
  };
}

/// A 402 names which limit it hit. The server keeps the member cap per
/// household, and the daily invite count per sender (`User`) and per
/// household. A 402 the client cannot place, a limit added later or a body
/// without its quota, is worded as the household's daily limit, the most
/// general of the three.
String _quota(HouseholdLocalizations l10n, InviteQuota? quota) =>
    switch (quota) {
      InviteQuota(resource: 'household_member_count') =>
        l10n.inviteErrorHouseholdFull,
      InviteQuota(resource: 'household_invite_daily_count', scope: 'User') =>
        l10n.inviteErrorDailyLimitYou,
      _ => l10n.inviteErrorDailyLimitHousehold,
    };
