import 'package:flutter/material.dart';
import 'package:notifications/l10n/notifications_localizations.dart';
import 'package:notifications/src/presentation/notification_presentation.dart';
import 'package:notifications/src/presentation/notification_target.dart';

// The household notifications (#475). Every payload carries `householdId`
// and `householdName`. Each function returns null when a field its wording
// or target needs is missing or isn't a string, and `presentNotification`
// then shows a plain row. Names and addresses go in as the server sent them.

/// `HouseholdInviteReceived`, sent to the invitee: opens their invites.
NotificationPresentation? presentHouseholdInviteReceived(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final householdName = _string(payload, 'householdName');
  final inviterName = _string(payload, 'inviterName');
  if (_string(payload, 'householdId') == null ||
      householdName == null ||
      inviterName == null) {
    return null;
  }
  return NotificationPresentation(
    icon: Icons.mail_outline,
    title: l10n.notificationHouseholdInviteReceivedTitle(
      inviterName,
      householdName,
    ),
    target: const InviteInboxTarget(),
  );
}

/// `HouseholdInviteAwaitingApproval`, sent to a household's owners and
/// admins: opens the household's invites awaiting approval.
NotificationPresentation? presentHouseholdInviteAwaitingApproval(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final householdId = _string(payload, 'householdId');
  final householdName = _string(payload, 'householdName');
  final inviterName = _string(payload, 'inviterName');
  if (householdId == null || householdName == null || inviterName == null) {
    return null;
  }
  final invitee = _invitee(payload);
  return NotificationPresentation(
    icon: Icons.how_to_reg_outlined,
    title: l10n.notificationHouseholdInviteAwaitingApprovalTitle(
      inviterName,
      householdName,
    ),
    detail: invitee == null
        ? l10n.notificationInviteeUnnamedDetail
        : l10n.notificationInviteeDetail(invitee),
    target: HouseholdInvitesTarget(householdId, awaitingApproval: true),
  );
}

/// `HouseholdInviteAccepted`, sent to the household's other members: opens
/// the household.
NotificationPresentation? presentHouseholdInviteAccepted(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final householdId = _string(payload, 'householdId');
  final householdName = _string(payload, 'householdName');
  final memberName = _string(payload, 'memberName');
  if (householdId == null || householdName == null || memberName == null) {
    return null;
  }
  return NotificationPresentation(
    icon: Icons.group_add_outlined,
    title: l10n.notificationHouseholdInviteAcceptedTitle(
      memberName,
      householdName,
    ),
    target: HouseholdTarget(householdId),
  );
}

/// `HouseholdInviteDeclined`, sent to the inviter and the household's owners
/// and admins: opens wherever the viewer's role lists the invite.
NotificationPresentation? presentHouseholdInviteDeclined(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final householdId = _string(payload, 'householdId');
  final householdName = _string(payload, 'householdName');
  if (householdId == null || householdName == null) return null;
  final invitee = _invitee(payload);
  return NotificationPresentation(
    icon: Icons.person_off_outlined,
    title: invitee == null
        ? l10n.notificationHouseholdInviteDeclinedUnnamedTitle(householdName)
        : l10n.notificationHouseholdInviteDeclinedTitle(invitee, householdName),
    target: DeclinedInviteTarget(householdId),
  );
}

/// `HouseholdOwnershipTransferred`, sent to the new household owner: opens
/// the household. The previous owner's name is null when their user was
/// deleted first.
NotificationPresentation? presentHouseholdOwnershipTransferred(
  NotificationsLocalizations l10n,
  Map<String, Object?> payload,
) {
  final householdId = _string(payload, 'householdId');
  final householdName = _string(payload, 'householdName');
  if (householdId == null || householdName == null) return null;
  final previousOwnerName = _string(payload, 'previousOwnerName');
  return NotificationPresentation(
    icon: Icons.workspace_premium_outlined,
    title: previousOwnerName == null
        ? l10n.notificationHouseholdOwnershipTransferredUnnamedTitle(
            householdName,
          )
        : l10n.notificationHouseholdOwnershipTransferredTitle(
            householdName,
            previousOwnerName,
          ),
    target: HouseholdTarget(householdId),
  );
}

/// The invitee as the invite names them: the name it was sent with, else
/// the address it was sent to. Null when it has neither, which the wording
/// covers.
String? _invitee(Map<String, Object?> payload) =>
    _string(payload, 'inviteeName') ?? _string(payload, 'inviteeEmail');

/// [payload]'s [key] when it holds a string with more than whitespace in it,
/// else null.
String? _string(Map<String, Object?> payload, String key) {
  final value = payload[key];
  return value is String && value.trim().isNotEmpty ? value : null;
}
