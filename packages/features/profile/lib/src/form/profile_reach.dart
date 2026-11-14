import 'package:models/domain.dart';
import 'package:profile/l10n/profile_localizations.dart';

/// A rung's name in the menu, and the line under it that says who that is,
/// or null for [Reach.unknown], which isn't offered. A switch, so a new
/// value doesn't compile until it has its copy. The menu offers the rungs
/// in [Reach.ladder]'s order (#547).
///
/// "Only me" names the server's staff, its owner, admins and moderators:
/// they can read every profile, whatever its reach, so it doesn't promise
/// no one else can.
({String label, String description})? profileReachCopy(
  ProfileLocalizations l10n,
  Reach reach,
) => switch (reach) {
  Reach.private => (
    label: l10n.profileReachPrivate,
    description: l10n.profileReachPrivateDescription,
  ),
  Reach.friends => (
    label: l10n.profileReachFriends,
    description: l10n.profileReachFriendsDescription,
  ),
  Reach.friendsOfFriends => (
    label: l10n.profileReachFriendsOfFriends,
    description: l10n.profileReachFriendsOfFriendsDescription,
  ),
  Reach.extendedNetwork => (
    label: l10n.profileReachExtendedNetwork,
    description: l10n.profileReachExtendedNetworkDescription,
  ),
  Reach.public => (
    label: l10n.profileReachPublic,
    description: l10n.profileReachPublicDescription,
  ),
  Reach.unknown => null,
};
