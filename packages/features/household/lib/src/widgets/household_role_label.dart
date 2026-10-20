import 'package:models/domain.dart';

import 'package:household/l10n/household_localizations.dart';

/// The words for [role]: the current user's on the household screen, and
/// the one an invite offers.
///
/// [HouseholdRole.unknown] gets its own words rather than a shrug. After the
/// #266 wire adapter it can only mean a role name this deployment defined
/// and this client does not know — the adapter throws on a malformed role
/// rather than degrading into it — so saying so is reporting real data, not
/// admitting a parse failure.
String householdRoleLabel(HouseholdLocalizations l10n, HouseholdRole role) =>
    switch (role) {
      HouseholdRole.householdOwner => l10n.householdDetailRoleOwner,
      HouseholdRole.householdAdmin => l10n.householdDetailRoleAdmin,
      HouseholdRole.householdMember => l10n.householdDetailRoleMember,
      HouseholdRole.householdGuest => l10n.householdDetailRoleGuest,
      HouseholdRole.unknown => l10n.householdDetailRoleUnknown,
    };
