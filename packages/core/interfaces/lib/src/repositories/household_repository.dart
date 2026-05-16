import 'package:models/domain.dart';

/// Read cache + queued-write repository for [Household] data.
///
/// ## Access boundary (members-only by default)
///
/// All read methods enforce a household-level visibility gate at the
/// repository layer: a caller who knows a household id they aren't
/// authorised to see gets a negative response rather than the cached
/// data. Specifically:
///
/// - [getHousehold] returns `null` for households the current user
///   isn't a member of, AND for households that have been tombstoned
///   (`deletedAt IS NOT NULL`), regardless of cache state.
/// - [getMembers] returns `const []` for the same two cases.
/// - [watchMembers] emits `const []` for the same two cases. The
///   gate is reactive — joining or being removed from the household,
///   or the household being tombstoned, automatically transitions
///   the stream's emissions.
/// - [getCurrentUserMember] returns `null` when the current user is
///   not a member; otherwise their own member row, even if the
///   household happens to be tombstoned (it's a private
///   self-introspection method, not a content-reveal method).
///
/// The cache writers ([cacheHousehold], [cacheMember], [cacheMembers])
/// are intentionally user-agnostic — the server has already done
/// auth filtering on the response payload, and the local cache may
/// legitimately contain rows for households the current user isn't a
/// member of (populated by friend-graph queries, etc.). The boundary
/// enforcement happens at read time so the cache stays a faithful
/// local mirror of what the server sent.
///
/// ## Future: per-household visibility
///
/// A `Household.visibility` field is on the roadmap (public /
/// restricted / friends-of-household tiers). When that lands, the
/// member-list reads will check visibility before the membership
/// preflight, so non-members can browse a friend's household roster
/// when the household opts in. Until then, the conservative
/// members-only rule applies — matching the auth contract the
/// backend's `HouseholdsService` enforces today.
abstract class HouseholdRepository {
  /// Returns all households the current user is a member of.
  ///
  /// Tombstoned households are excluded.
  Future<List<Household>> getHouseholds();

  /// Returns the [Household] with [id], or `null` if any of:
  ///
  /// - the household is not cached locally
  /// - the current user is not a member of it
  /// - the household has been tombstoned (`deletedAt IS NOT NULL`)
  ///
  /// The three cases are deliberately indistinguishable to the caller,
  /// preserving the membership boundary even for users who guess at
  /// household ids they shouldn't have.
  Future<Household?> getHousehold(String id);

  /// Returns all [HouseholdMember] entries for [householdId].
  ///
  /// Returns `const []` if any of:
  ///
  /// - the household has no member rows cached locally
  /// - the current user is not a member of [householdId] (no leaking
  ///   the roster to non-members, even if the rows happen to be in
  ///   the cache from a prior query)
  /// - [householdId] refers to a tombstoned household
  ///
  /// The three cases are deliberately indistinguishable to the caller.
  Future<List<HouseholdMember>> getMembers(String householdId);

  /// Returns the [HouseholdMember] record for the current user
  /// in [householdId], or `null` if not a member.
  ///
  /// Unlike [getHousehold] and [getMembers], this method does **not**
  /// gate on the household being live — a user querying their own
  /// member row in a recently-tombstoned household still gets it back.
  /// This is a self-introspection method, not a content-reveal method.
  Future<HouseholdMember?> getCurrentUserMember(String householdId);

  /// Upserts a [Household] from a server response. User-agnostic by
  /// design — the read-side boundary enforces visibility.
  Future<void> cacheHousehold(Household household);

  /// Upserts a [HouseholdMember] from a server response. User-agnostic
  /// by design — the read-side boundary enforces visibility.
  Future<void> cacheMember(HouseholdMember member);

  /// Upserts a batch of members. Same user-agnostic semantics as
  /// [cacheMember].
  Future<void> cacheMembers(List<HouseholdMember> members);

  /// Watches all households the current user is a member of.
  /// Tombstoned households are excluded. Emits a fresh list on every
  /// membership change or household upsert.
  Stream<List<Household>> watchHouseholds();

  /// Watches the member list for [householdId].
  ///
  /// Emits `const []` whenever any of the negative cases from
  /// [getMembers] holds (non-member, tombstoned household, empty
  /// roster). The gate is reactive: a join or leave automatically
  /// transitions the stream between empty and full-list emissions.
  Stream<List<HouseholdMember>> watchMembers(String householdId);
}
