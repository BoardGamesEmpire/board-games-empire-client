import 'package:models/domain.dart';

/// What [HouseholdRepository.cacheHouseholdWithRoster] did with one
/// household from a server read (#268).
enum HouseholdRosterWrite {
  /// The household and its roster now match the server's.
  replaced,

  /// The household was written, but the roster was empty or did not
  /// include the current user, so it was only merged in: no cached member
  /// was removed.
  merged,

  /// Nothing was written: the cached household is dirty or local-only.
  held,
}

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
/// The cache writers ([cacheHousehold], [cacheMember], [cacheMembers],
/// [cacheHouseholdWithRoster]) and [purgeHouseholdsAbsentFrom] are
/// server-driven: they apply payloads the server already auth-filtered,
/// and are not user-facing mutations.
///
/// ## Removals made elsewhere (#268)
///
/// A household the current user left, was removed from, or saw deleted on
/// another device (or the web UI) leaves their list on the next hydrate,
/// by [purgeHouseholdsAbsentFrom]. A member removed from a household the
/// user is still in drops out of its roster on the next write of it, by
/// [cacheHouseholdWithRoster]. Between passes the read-side membership
/// gate below still trusts a cache the server may have moved past, so the
/// stale window now closes on the next hydrate rather than never. The
/// exception is a whole household for a user whose list does not fit one
/// page: nothing short of a single-page read licenses the purge.
///
/// **TODO(household-mutations-phase-4)**: this device's own membership
/// mutations (#122) will update the local member rows in the same
/// transaction they enqueue against the sync queue. Until the server
/// accepts one, the next hydrate still carries the old roster, so each
/// must hold its household against both writers above: mark it dirty,
/// which both already honour, or give member rows sync flags of their own
/// and teach both writers about them in the same change.
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
  /// Returns all households the current user is a member of, ordered by
  /// [Household.name] ascending (case-insensitively), oldest
  /// [Household.createdAt] first on a tie (#269 D3).
  ///
  /// The order is part of the contract, not an implementation detail: the
  /// list screen renders it directly, and [watchHouseholds] must agree
  /// with it.
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
  /// When [serverHousehold]'s id equals [localId], the optimistic row is
  /// acknowledged: it takes the server's values and both sync flags are
  /// cleared. This is the only write that clears them. When the ids differ,
  /// [serverHousehold] is written under the canonical id by the same rule
  /// as [cacheHousehold], the synthesized owner member row is migrated onto
  /// it, and the stale optimistic household row is dropped. When
  /// [completedSyncQueueId] is provided, that queue entry is marked
  /// completed in the **same transaction**; if any step throws, all of it
  /// rolls back.
  ///
  /// The synthesized owner member row keeps its client-generated id. The
  /// next server write of that membership replaces it, since member writes
  /// resolve on `(householdId, userId)` (#267), and nothing in the
  /// create-only flow reads it before then. The exception is
  /// a server membership row already cached under the canonical id (a
  /// hydrate ran first): that row is kept, and the synthesized row for the
  /// same user is dropped rather than re-pointed onto it.
  Future<void> reconcileCreatedHousehold(
    Household serverHousehold, {
    required String localId,
    String? completedSyncQueueId,
  });

  /// The canonical id [reconcileCreatedHousehold] moved [localId] onto, or
  /// null if it has not — including when the server kept the local id, and
  /// when a reconcile rolled back.
  ///
  /// For a screen that holds a household by id when the id changes under
  /// it (#306): one open during the reconcile, or one rebuilt on the local
  /// id afterwards. The optimistic row is gone by then, so the local id
  /// reads as a household that does not exist.
  ///
  /// Once the record is readable, [watchHouseholds] emits again, so a
  /// subscriber that checks this on every emission sees the move even if
  /// it heard the local row vanish first.
  ///
  /// Kept in memory, for the life of this repository, which is the user
  /// session. Nothing restores a route across an app restart, so no route
  /// can hold a local id longer than that. Never throws, including after
  /// disposal.
  String? reconciledHouseholdId(String localId);

  /// Upserts a [Household] from a server response. User-agnostic by
  /// design — the read-side boundary enforces visibility.
  ///
  /// The row is written with `isDirty` and `isLocalOnly` both `false`,
  /// whatever [household] carries: a server copy has no local sync state.
  /// An existing row with either flag set is left untouched, flags and
  /// values, tombstone included. It holds local changes the server has not
  /// accepted yet, and only the server's acknowledgement of them may
  /// overwrite it ([reconcileCreatedHousehold], for a create).
  Future<void> cacheHousehold(Household household);

  /// Upserts a [HouseholdMember] from a server response. User-agnostic
  /// by design — the read-side boundary enforces visibility.
  Future<void> cacheMember(HouseholdMember member);

  /// Upserts a batch of members. Same user-agnostic semantics as
  /// [cacheMember].
  Future<void> cacheMembers(List<HouseholdMember> members);

  /// Writes one household from a server read together with the roster
  /// that read embedded, and makes the cached roster match it (#268): a
  /// cached member whose user is not in [roster] is deleted and the rest
  /// are upserted as by [cacheMembers], in one transaction.
  ///
  /// This is how a member removed on another device leaves this one. It
  /// relies on the server reading each household and its roster together,
  /// which the household list does.
  ///
  /// Two cases write less, and the result says which:
  ///
  /// - A cached household that is `isDirty` or `isLocalOnly` is left
  ///   alone, roster included ([HouseholdRosterWrite.held]). The queue
  ///   owns it until the server acknowledges it, as for [cacheHousehold].
  /// - A roster that is empty or leaves out the current user is not
  ///   trusted to say who left. The household is written and the roster
  ///   merged in, deleting no one ([HouseholdRosterWrite.merged]). Applied
  ///   as given it would delete the current user's own row, and the
  ///   household would vanish from their list.
  Future<HouseholdRosterWrite> cacheHouseholdWithRoster(
    Household household,
    List<HouseholdMember> roster,
  );

  /// The households [purgeHouseholdsAbsentFrom] could remove right now: the
  /// cached households the current user has a member row in, less any that
  /// are `isDirty` or `isLocalOnly` (#268).
  ///
  /// Read it **before** requesting the snapshot, and pass it to the purge.
  /// A household that became purgeable after this read (created, or
  /// confirmed by the server, while the request was in flight) is one the
  /// snapshot could not have seen, and the purge leaves it alone. This
  /// reads the database, so a write from any repository over it counts,
  /// another browser tab's included.
  Future<Set<String>> purgeableHouseholdIds();

  /// Removes the current user from each household in [purgeable] that
  /// [snapshotIds] does not name, in one transaction, and returns the ids
  /// it removed them from (#268).
  ///
  /// [snapshotIds] must be **one consistent read of every household** the
  /// server would return for the current user. For the household list that
  /// is a first page with `hasMore: false`; a walk across pages is not
  /// one, and absence from it proves nothing.
  ///
  /// [purgeable] is a [purgeableHouseholdIds] read taken before the
  /// snapshot was requested. Nothing outside it is removed, and neither is
  /// a household in it that is no longer purgeable: one edited since, which
  /// the queue now owns.
  ///
  /// Only the current user's member row is deleted, because the snapshot
  /// speaks for their memberships and nobody else's. The cache is shared by
  /// everyone who signs in to this server on this device, and another of
  /// them may still belong to the household. A household left with no
  /// member row at all is deleted with it: no read can reach it.
  ///
  /// Rows are deleted, not tombstoned: the server has already spoken, and a
  /// tombstone is a local intent waiting for a server to settle it.
  Future<Set<String>> purgeHouseholdsAbsentFrom(
    Set<String> snapshotIds, {
    required Set<String> purgeable,
  });

  /// Watches all households the current user is a member of, in
  /// [getHouseholds]'s order. Tombstoned households are excluded. Emits a
  /// fresh list on every membership change or household upsert.
  Stream<List<Household>> watchHouseholds();

  /// Watches the member list for [householdId].
  ///
  /// Emits `const []` whenever any of the negative cases from
  /// [getMembers] holds (non-member, tombstoned household, empty
  /// roster). The gate is reactive: a join or leave automatically
  /// transitions the stream between empty and full-list emissions.
  Stream<List<HouseholdMember>> watchMembers(String householdId);
}
