import 'package:freezed_annotation/freezed_annotation.dart';

/// Household membership role.
///
/// Maps to the server-side `Role.name` string surfaced through the
/// `HouseholdRole` join. Wire format mirrors the household-prefixed
/// entries of the server `SystemRole` enum.
///
/// Server deployments are free to define custom roles whose names do
/// not match a known value here. Such values deserialize to [unknown]
/// via `@JsonKey(unknownEnumValue: HouseholdRole.unknown)` on the
/// consuming `HouseholdMember.role` field, allowing the client to
/// degrade gracefully rather than throw.
///
/// See: `prisma/models/permissions/role.prisma` in
/// `board-games-empire-backend`.
enum HouseholdRole {
  @JsonValue('HouseholdOwner')
  householdOwner,
  @JsonValue('HouseholdAdmin')
  householdAdmin,
  @JsonValue('HouseholdMember')
  householdMember,
  @JsonValue('HouseholdGuest')
  householdGuest,

  /// Fallback when the server returns a role name not in the known set.
  /// Never sent back to the server.
  unknown,
}
