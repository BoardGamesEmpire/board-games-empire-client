import 'package:freezed_annotation/freezed_annotation.dart';
import 'household_role.dart';

part 'household_member.freezed.dart';
part 'household_member.g.dart';

/// Membership record linking a user to a household.
///
/// `role` was previously a stringly-typed `roleName`; it is now a typed
/// [HouseholdRole] enum. Unknown server-defined role names deserialize
/// to [HouseholdRole.unknown] rather than failing.
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

    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _HouseholdMember;

  factory HouseholdMember.fromJson(Map<String, dynamic> json) =>
      _$HouseholdMemberFromJson(json);

  bool get isOwner => role == HouseholdRole.householdOwner;
  bool get isAdmin =>
      role == HouseholdRole.householdOwner ||
      role == HouseholdRole.householdAdmin;
}
