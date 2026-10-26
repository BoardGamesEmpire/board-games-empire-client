import 'package:freezed_annotation/freezed_annotation.dart';

import '../user/person_name.dart';
import 'household_role.dart';

part 'household_member.freezed.dart';
part 'household_member.g.dart';

/// Membership record linking a user to a household.
///
/// `role` was previously a stringly-typed `roleName`; it is now a typed
/// [HouseholdRole] enum. Unknown server-defined role names deserialize
/// to [HouseholdRole.unknown] rather than failing.
///
/// [username], [displayName] and [avatarUrl] come from the `user` projection
/// the household list embeds in each member (#304). A row can lack all three
/// until a hydrate writes them: the owner row a local create synthesizes has
/// none until the server's own row replaces it.
@freezed
abstract class HouseholdMember with _$HouseholdMember {
  const HouseholdMember._();

  const factory HouseholdMember({
    required String id,
    required String userId,
    required String householdId,

    /// When true, household game pool includes all member games.
    @Default(true) bool showAllGames,

    /// Membership role. Null when the server returns no role binding.
    /// Unrecognized server role names deserialize to [HouseholdRole.unknown].
    @JsonKey(unknownEnumValue: HouseholdRole.unknown) HouseholdRole? role,

    /// The member's account name, display name and avatar, as the list
    /// embeds them. All three are null where none is cached, and
    /// [displayName] and [avatarUrl] are also null for an account that has
    /// not set them.
    String? username,
    String? displayName,
    String? avatarUrl,

    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _HouseholdMember;

  factory HouseholdMember.fromJson(Map<String, dynamic> json) =>
      _$HouseholdMemberFromJson(json);

  bool get isOwner => role == HouseholdRole.householdOwner;
  bool get isAdmin =>
      role == HouseholdRole.householdOwner ||
      role == HouseholdRole.householdAdmin;

  /// The name to show for this member: [displayName], else [username]. Null
  /// where neither is cached.
  String? get name => personName(displayName: displayName, username: username);
}
