import 'package:app_shell/src/router/app_router.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:notifications/notifications.dart';
import 'package:observability/observability.dart';

final BgeLogger _log = BgeLogger('bge.shell.notifications');

/// The location [target] opens, for a notification the user tapped (#475).
///
/// A declined invite is listed where the user's role in its household
/// lets them read it: the household's invites for its owners and admins,
/// and for anyone else the invites the user sent, which every member can
/// read, each on its Declined filter, so the decline shows. The notification
/// doesn't say who sent the invite, so the role is read from [households],
/// the device's cache. Any other role, no member record there, no cache, or
/// a read that fails opens the sent invites.
///
/// Never throws: a notification always opens somewhere.
Future<String> notificationTargetLocation(
  NotificationTarget target, {
  required HouseholdRepository? households,
}) async => switch (target) {
  InviteInboxTarget() => AppRoutes.invites,
  HouseholdTarget(:final householdId) => AppRoutes.householdDetailOf(
    householdId,
  ),
  HouseholdInvitesTarget(:final householdId, :final awaitingApproval) =>
    AppRoutes.householdInvitesOf(
      householdId,
      awaitingApproval: awaitingApproval,
    ),
  DeclinedInviteTarget(:final householdId) => await _declinedInviteLocation(
    householdId,
    households,
  ),
};

/// Where a declined invite to [householdId] is listed for the user.
Future<String> _declinedInviteLocation(
  String householdId,
  HouseholdRepository? households,
) async {
  final sent = AppRoutes.invitesSentOf(declined: true);
  if (households == null) return sent;
  final HouseholdMember? viewer;
  try {
    viewer = await households.getCurrentUserMember(householdId);
  } on Object catch (error, stackTrace) {
    // A repository closed with its session throws here, as a failed read
    // does: the sent invites are open to every member.
    _log.warn(
      "Couldn't read the user's role for a declined invite; opening the "
      'invites they sent',
      error: error,
      stackTrace: stackTrace,
    );
    return sent;
  }
  return switch (viewer?.role) {
    HouseholdRole.householdOwner ||
    HouseholdRole.householdAdmin => AppRoutes.householdInvitesOf(
      householdId,
      declined: true,
    ),
    _ => sent,
  };
}
