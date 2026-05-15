import 'package:models/domain.dart';

/// Read cache + queued-write repository for [Household] data.
abstract class HouseholdRepository {
  /// Returns all households the current user is a member of.
  Future<List<Household>> getHouseholds();

  /// Returns a specific [Household] by [id], or null if not cached.
  Future<Household?> getHousehold(String id);

  /// Returns all [HouseholdMember] entries for [householdId].
  Future<List<HouseholdMember>> getMembers(String householdId);

  /// Returns the [HouseholdMember] record for the current user
  /// in [householdId], or null if not a member.
  Future<HouseholdMember?> getCurrentUserMember(String householdId);

  /// Upserts a [Household] from a server response.
  Future<void> cacheHousehold(Household household);

  /// Upserts a [HouseholdMember] from a server response.
  Future<void> cacheMember(HouseholdMember member);

  /// Upserts a batch of members.
  Future<void> cacheMembers(List<HouseholdMember> members);

  /// Watches all cached households.
  Stream<List<Household>> watchHouseholds();

  /// Watches a specific household's member list.
  Stream<List<HouseholdMember>> watchMembers(String householdId);
}
