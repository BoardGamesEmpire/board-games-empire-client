import 'package:models/domain.dart';

import 'package:household/l10n/household_localizations.dart';

/// The line on an invite's row that says when it runs out (#487), so every
/// invite list words it alike.
///
/// An outstanding invite says when it expires, and an expired one when it
/// did, in the device's own time zone. A settled invite has none: its expiry
/// no longer means anything, so its row says [inviteSettledLabel] instead.
/// Neither has words for a status this client does not know.
String? inviteExpiryLine(HouseholdLocalizations l10n, HouseholdInvite invite) =>
    switch (invite.status) {
      HouseholdInviteStatus.pending || HouseholdInviteStatus.awaitingApproval =>
        l10n.householdInviteExpires(invite.expiresAt.toLocal()),
      HouseholdInviteStatus.expired => l10n.householdInviteExpired(
        invite.expiresAt.toLocal(),
      ),
      HouseholdInviteStatus.accepted ||
      HouseholdInviteStatus.declined ||
      HouseholdInviteStatus.withdrawn ||
      HouseholdInviteStatus.revoked ||
      HouseholdInviteStatus.unknown => null,
    };

/// The words for a settled invite's [status], for its row in place of an
/// expiry. Null for an outstanding or expired invite, which says when it
/// runs out instead, and for a status this client does not know.
String? inviteSettledLabel(
  HouseholdLocalizations l10n,
  HouseholdInviteStatus status,
) => switch (status) {
  HouseholdInviteStatus.accepted => l10n.inviteStatusAccepted,
  HouseholdInviteStatus.declined => l10n.inviteStatusDeclined,
  HouseholdInviteStatus.withdrawn => l10n.inviteStatusWithdrawn,
  HouseholdInviteStatus.revoked => l10n.inviteStatusRevoked,
  HouseholdInviteStatus.pending ||
  HouseholdInviteStatus.awaitingApproval ||
  HouseholdInviteStatus.expired ||
  HouseholdInviteStatus.unknown => null,
};
