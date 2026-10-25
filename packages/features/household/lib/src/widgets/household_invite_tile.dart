import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:household/l10n/household_localizations.dart';

import '../invites/household_invite_permissions.dart';
import '../invites/invite_expiry_line.dart';
import 'household_invite_awaiting_badge.dart';
import 'household_invite_busy_indicator.dart';
import 'household_role_label.dart';

/// One invite on a household's invite list (#455): who it is for, the role
/// it offers, who sent it and when it expires, and the actions the viewer
/// may take on it.
///
/// Presentation only. The caller decides which [actions] to offer and
/// handles a press, confirming first where it asks to.
class HouseholdInviteTile extends StatelessWidget {
  const HouseholdInviteTile({
    required this.invite,
    required this.actions,
    required this.busy,
    required this.onAction,
    super.key,
  });

  /// Per-action button key: `household_invite_tile.<action>_<id>`.
  static Key actionKey(HouseholdInviteRowAction action, String inviteId) =>
      Key('household_invite_tile.${action.name}_$inviteId');

  final HouseholdInvite invite;

  /// The actions to offer, from `HouseholdInvitePermissions.rowActions`.
  final Set<HouseholdInviteRowAction> actions;

  /// An action on this invite is running. Its buttons are disabled meanwhile
  /// rather than hidden, so the row does not jump.
  final bool busy;

  final void Function(HouseholdInviteRowAction action) onAction;

  /// What the revoke action is called on [invite]: refusing an invite that
  /// awaits approval reads as turning it down.
  static String revokeLabel(
    HouseholdLocalizations l10n,
    HouseholdInvite invite,
  ) => invite.status == HouseholdInviteStatus.awaitingApproval
      ? l10n.householdInviteTurnDown
      : l10n.householdInviteRevoke;

  @override
  Widget build(BuildContext context) {
    final l10n = HouseholdLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final role = invite.role;
    final awaiting = invite.status == HouseholdInviteStatus.awaitingApproval;
    final expiry = inviteExpiryLine(l10n, invite);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text(invite.inviteeLabel ?? l10n.householdInviteToAccount),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (role != null) Text(householdRoleLabel(l10n, role)),
              if (awaiting) const HouseholdInviteAwaitingBadge(),
              Text(l10n.householdInviteFrom(invite.inviter.label)),
              if (expiry != null) Text(expiry),
            ],
          ),
          trailing: busy ? const HouseholdInviteBusyIndicator() : null,
        ),
        if (actions.isNotEmpty)
          Padding(
            padding: EdgeInsetsDirectional.only(
              start: tokens.spaceMd,
              end: tokens.spaceMd,
              bottom: tokens.spaceSm,
            ),
            child: Wrap(
              spacing: tokens.spaceSm,
              runSpacing: tokens.spaceSm,
              children: [
                // Approve first: on a row awaiting approval it is the
                // answer most likely wanted.
                if (actions.contains(HouseholdInviteRowAction.approve))
                  FilledButton.tonal(
                    key: actionKey(HouseholdInviteRowAction.approve, invite.id),
                    onPressed: busy
                        ? null
                        : () => onAction(HouseholdInviteRowAction.approve),
                    child: Text(l10n.householdInviteApprove),
                  ),
                if (actions.contains(HouseholdInviteRowAction.revoke))
                  TextButton(
                    key: actionKey(HouseholdInviteRowAction.revoke, invite.id),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    onPressed: busy
                        ? null
                        : () => onAction(HouseholdInviteRowAction.revoke),
                    child: Text(revokeLabel(l10n, invite)),
                  ),
                if (actions.contains(HouseholdInviteRowAction.withdraw))
                  OutlinedButton(
                    key: actionKey(
                      HouseholdInviteRowAction.withdraw,
                      invite.id,
                    ),
                    onPressed: busy
                        ? null
                        : () => onAction(HouseholdInviteRowAction.withdraw),
                    child: Text(l10n.householdInviteWithdraw),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
