import 'package:models/domain.dart';

/// Read cache + cache-writer + create repository for [Household] data.
///
/// ## Scope: create + read-cache + cache-writer
///
/// [create] is the first user-initiated mutation (P4, #39): a signed-in
/// user creating a household they own. The remaining household mutations
/// (leave, kick, transfer-ownership, delete, invite, role changes) are
/// still deferred — they land with the membership work (#122), at which
/// point membership-mutation sync ops join the queue.
///
/// The cache writers ([cacheHousehold], [cacheMember], [cacheMembers])
/// are server-driven cache populators that accept payloads the server
/// already auth-filtered, not user-facing mutations.
///
/// **TODO(household-mutations-phase-4)**: a known gap exists between
/// now and the membership work (#122). If a user leaves a household on
/// another device (or the web UI), this device's cache won't know until
/// a full resync arrives, and the read-side membership gate below trusts
/// the cache — so a stale local member row will keep the household
/// visible to a user who has actually been removed. The mitigation
/// today is the read-cache nature of the repo: every server
/// response refreshes the membership, so the stale window closes
/// on the next sync tick. #122 will close it deterministically
/// by introducing membership-mutation sync ops that update the
/// local member rows in the same transaction they enqueue against
/// the sync queue.
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

  // ── Mutations (P4, #39) ──────────────────────────────────────────

  /// Creates a household owned by the current user.
  ///
  /// Optimistically writes the household locally with `isLocalOnly = true`
  /// and synthesizes the current user's `HouseholdOwner` member row — so
  /// the household appears in [getHouseholds] / [watchHouseholds]
  /// immediately (the read gate requires a member row) — then enqueues a
  /// `CreateHouseholdOperation`. The two writes plus the enqueue are one
  /// transaction: if the enqueue fails, the optimistic writes roll back.
  ///
  /// [language] is an IETF BCP 47 tag; [visibility] a `Private` | `Friends`
  /// enum name — both optional and forwarded verbatim on the enqueued op.
  ///
  /// This method does **not** contact the server. A coordinator sends the
  /// queued op and calls [reconcileCreatedHousehold] with the response.
  ///
  /// Returns the optimistic [Household] (client-assigned cuid2 id,
  /// `isDirty` / `isLocalOnly` both `true`) together with the
  /// `syncQueueId` of the enqueued `CreateHouseholdOperation`, which the
  /// coordinator threads into [reconcileCreatedHousehold] so the op is
  /// closed once the server confirms (otherwise the sync worker would
  /// re-create the household). Throws [ArgumentError] if [name] is blank.
  Future<({Household household, String syncQueueId})> create({
    required String name,
    String? description,
    String? image,
    String? language,
    String? visibility,
  });

  /// Reconciles a server-confirmed household against the optimistic row
  /// [create] wrote, correlated by [localId] (the client cuid2 the op
  /// carried — a household has no natural business key, so this id is the
  /// only handle tying the response to the optimistic row).
  ///
  /// The server assigns the canonical id (its create DTO has no id field).
  /// When [serverHousehold]'s id differs from [localId], this migrates the
  /// synthesized owner member row onto the canonical id and drops the stale
  /// optimistic household row, then upserts [serverHousehold] with the sync
  /// flags cleared. When [completedSyncQueueId] is provided, that queue
  /// entry is marked completed in the **same transaction**; if any step
  /// throws, all of it rolls back.
  ///
  /// The synthesized owner member row keeps its client-generated id; the
  /// authoritative member id is reconciled by the membership sync (#122),
  /// not here — nothing in the create-only flow reads it.
  Future<void> reconcileCreatedHousehold(
    Household serverHousehold, {
    required String localId,
    String? completedSyncQueueId,
  });

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
