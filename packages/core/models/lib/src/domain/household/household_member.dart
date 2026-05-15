import 'package:freezed_annotation/freezed_annotation.dart';

part 'household_member.freezed.dart';
part 'household_member.g.dart';

@freezed
abstract class HouseholdMember with _$HouseholdMember {
  const HouseholdMember._();

  const factory HouseholdMember({
    required String id,
    required String userId,
    required String householdId,

    /// When true, household game pool includes all member games.
    @Default(true) bool showAllGames,

    /// Role name from server RBAC (e.g. 'HouseholdOwner', 'HouseholdMember').
    String? roleName,

    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _HouseholdMember;

  factory HouseholdMember.fromJson(Map<String, dynamic> json) =>
      _$HouseholdMemberFromJson(json);

  bool get isOwner => roleName == 'HouseholdOwner';
  bool get isAdmin =>
      roleName == 'HouseholdOwner' || roleName == 'HouseholdAdmin';
}
