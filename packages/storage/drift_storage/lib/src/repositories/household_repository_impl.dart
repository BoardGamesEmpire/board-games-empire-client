import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../databases/server_database.dart';

/// Read cache + cache-writer implementation of [HouseholdRepository].
///
/// Scoped to a current user via [currentUserId]. Every read path that
/// returns household data — list, single-by-id, watch, member list,
/// member watch — gates on the current user being a member of the
/// household in question AND on the household itself being live
/// (not tombstoned). A caller who passes an id for a household they
/// don't belong to, or for one that's been deleted, sees:
///
/// - `null` from [getHousehold]
/// - `const []` from [getMembers]
/// - a stream that emits `const []` from [watchMembers]
///
/// … regardless of whether the household and its members are present
/// in the local cache. This holds the household-level visibility
/// boundary at the read layer rather than trusting upstream callers
/// to only pass ids they obtained from [getHouseholds].
///
/// The cache writers (`cacheHousehold`, `cacheMember`, `cacheMembers`)
/// remain user-agnostic: the server has already done auth filtering
/// on the response payload, and the local cache may legitimately
/// contain rows for households the current user isn't a member of
/// (e.g. a household their friend belongs to, populated by a friend
/// graph query). The boundary enforcement happens at read time so
/// the cache stays a faithful local mirror of what the server sent.
///
/// ## Scope today: no queued writes
///
/// There are no mutation methods on this implementation — no
/// `leaveHousehold`, `removeMember`, `transferOwnership`, etc. —
/// because user-initiated household mutations are Phase 4 scope.
/// Today's "cache-writer" methods ([cacheHousehold], [cacheMember],
/// [cacheMembers]) are server-driven populators that accept payloads
/// the server already auth-filtered, not user-initiated mutations
/// against a sync queue.
///
/// **TODO(household-mutations-phase-4)**: a stale-cache window
/// exists between server-side membership changes (leaves, removals,
/// role swaps performed via the web UI or another device) and the
/// next resync arriving at this device. During that window the
/// read-side membership gate is making decisions on a cache the
/// server has already moved past — e.g., a user who has actually
/// been removed from a household will still see it via
/// [getHousehold] / [watchHouseholds] until the cache catches up.
/// Phase 4 will close this by introducing membership-mutation sync
/// ops that update the local member rows in the same Drift
/// transaction they enqueue against the sync queue. Until then the
/// gate is best-effort, with eventual consistency at the next
/// sync tick.
///
/// ## Future: per-household visibility
///
/// The current rule is binary — you're either a member of the
/// household or you see nothing. A planned `visibility` field on
/// [Household] will let households opt into being viewable by
/// non-members (e.g. public households, friends-of-friends, or
/// friends-of-household-members). When that field lands:
///
/// - [getMembers] and [watchMembers] will check
///   `household.visibility` first; for households marked public (or
///   any tier the current user qualifies for under the visibility
///   rules), the membership preflight will be skipped and the full
///   member list returned.
/// - [getHousehold] will likewise return the household to non-members
///   when the visibility tier permits.
///
/// Until then the conservative "members-only" rule applies, matching
/// the auth contract the server-side `HouseholdsService` enforces
/// today.
class HouseholdRepositoryImpl implements HouseholdRepository {
  HouseholdRepositoryImpl({
    required ServerDatabase db,
    required String currentUserId,
  }) : _db = db,
       _userId = currentUserId;

  final ServerDatabase _db;
  final String _userId;

  @override
  Future<List<Household>> getHouseholds() async {
    final query = _db.select(_db.householdsTable).join([
      innerJoin(
        _db.householdMembersTable,
        _db.householdMembersTable.householdId.equalsExp(
              _db.householdsTable.id,
            ) &
            _db.householdMembersTable.userId.equals(_userId),
      ),
    ])..where(_db.householdsTable.deletedAt.isNull());

    final rows = await query.get();
    return rows
        .map((r) => _mapHousehold(r.readTable(_db.householdsTable)))
        .toList();
  }

  @override
  Future<Household?> getHousehold(String householdId) async {
    final query =
        _db.select(_db.householdsTable).join([
          innerJoin(
            _db.householdMembersTable,
            _db.householdMembersTable.householdId.equalsExp(
                  _db.householdsTable.id,
                ) &
                _db.householdMembersTable.userId.equals(_userId),
          ),
        ])..where(
          _db.householdsTable.id.equals(householdId) &
              _db.householdsTable.deletedAt.isNull(),
        );

    final row = await query.getSingleOrNull();
    return row == null
        ? null
        : _mapHousehold(row.readTable(_db.householdsTable));
  }

  @override
  Future<List<HouseholdMember>> getMembers(String householdId) async {
    final rows = await _membersQuery(householdId).get();
    return rows
        .map((r) => _mapMember(r.readTable(_db.householdMembersTable)))
        .toList();
  }

  @override
  Future<HouseholdMember?> getCurrentUserMember(String householdId) async {
    final row =
        await (_db.select(_db.householdMembersTable)..where(
              (t) =>
                  t.householdId.equals(householdId) & t.userId.equals(_userId),
            ))
            .getSingleOrNull();
    return row == null ? null : _mapMember(row);
  }

  @override
  Future<void> cacheHousehold(Household household) async {
    await _db
        .into(_db.householdsTable)
        .insertOnConflictUpdate(
          HouseholdsTableCompanion.insert(
            id: household.id,
            name: household.name,
            description: Value(household.description),
            image: Value(household.image),
            deletedAt: Value(household.deletedAt),
            createdAt: household.createdAt,
            updatedAt: household.updatedAt,
          ),
        );
  }

  @override
  Future<void> cacheMember(HouseholdMember member) async {
    await _db
        .into(_db.householdMembersTable)
        .insertOnConflictUpdate(_memberToCompanion(member));
  }

  @override
  Future<void> cacheMembers(List<HouseholdMember> members) async {
    await _db.batch((b) {
      for (final m in members) {
        b.insert(
          _db.householdMembersTable,
          _memberToCompanion(m),
          onConflict: DoUpdate((old) => _memberToCompanion(m)),
        );
      }
    });
  }

  @override
  Stream<List<Household>> watchHouseholds() {
    final query = _db.select(_db.householdsTable).join([
      innerJoin(
        _db.householdMembersTable,
        _db.householdMembersTable.householdId.equalsExp(
              _db.householdsTable.id,
            ) &
            _db.householdMembersTable.userId.equals(_userId),
      ),
    ])..where(_db.householdsTable.deletedAt.isNull());

    return query.watch().map(
      (rows) => rows
          .map((r) => _mapHousehold(r.readTable(_db.householdsTable)))
          .toList(),
    );
  }

  @override
  Stream<List<HouseholdMember>> watchMembers(String householdId) {
    return _membersQuery(householdId).watch().map(
      (rows) => rows
          .map((r) => _mapMember(r.readTable(_db.householdMembersTable)))
          .toList(),
    );
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────────

  /// Common selectable for [getMembers] and [watchMembers]: returns
  /// the members of [householdId] iff (a) the household exists and
  /// is not tombstoned, AND (b) the current user is one of its
  /// members.
  ///
  /// Implementation uses two inner joins on the same
  /// `household_members` row:
  ///
  /// - One to [householdsTable] filtered by `deletedAt IS NULL`,
  ///   which fails the row if the household itself has been
  ///   tombstoned.
  /// - One to an alias `me` of [householdMembersTable] filtered by
  ///   the current user id, which fails the row if the current user
  ///   isn't a member. The
  ///   `household_members_household_user_unique_idx` unique index on
  ///   `(householdId, userId)` guarantees at most one `me` row per
  ///   household, so the self-join can't fan out duplicates.
  ///
  /// Both joins must match for any rows to come back, so the empty
  /// result correctly covers all three negative cases: deleted
  /// household, non-member, or genuinely empty household.
  ///
  /// TODO(visibility): when [Household.visibility] lands, public /
  /// restricted tiers can bypass the `me` self-join so non-members
  /// can browse a friend's household roster. See class doc.
  JoinedSelectStatement _membersQuery(String householdId) {
    final me = _db.alias(_db.householdMembersTable, 'me');
    return _db.select(_db.householdMembersTable).join([
      innerJoin(
        _db.householdsTable,
        _db.householdsTable.id.equalsExp(
              _db.householdMembersTable.householdId,
            ) &
            _db.householdsTable.deletedAt.isNull(),
      ),
      innerJoin(
        me,
        me.householdId.equalsExp(_db.householdMembersTable.householdId) &
            me.userId.equals(_userId),
      ),
    ])..where(_db.householdMembersTable.householdId.equals(householdId));
  }

  // ── Mappers ──────────────────────────────────────────────────────────────────────

  Household _mapHousehold(HouseholdsTableData row) => Household(
    id: row.id,
    name: row.name,
    description: row.description,
    image: row.image,
    deletedAt: row.deletedAt,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  HouseholdMember _mapMember(HouseholdMembersTableData row) => HouseholdMember(
    id: row.id,
    userId: row.userId,
    householdId: row.householdId,
    showAllGames: row.showAllGames,
    role: _decodeRole(row.roleName),
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  HouseholdMembersTableCompanion _memberToCompanion(HouseholdMember m) =>
      HouseholdMembersTableCompanion.insert(
        id: m.id,
        userId: m.userId,
        householdId: m.householdId,
        showAllGames: Value(m.showAllGames),
        roleName: Value(_encodeRole(m.role)),
        createdAt: m.createdAt,
        updatedAt: m.updatedAt,
      );

  /// Maps a persisted role-name string to a typed [HouseholdRole].
  /// Unknown server-defined names map to [HouseholdRole.unknown].
  static HouseholdRole? _decodeRole(String? value) {
    if (value == null) return null;
    return switch (value) {
      'HouseholdOwner' => HouseholdRole.householdOwner,
      'HouseholdAdmin' => HouseholdRole.householdAdmin,
      'HouseholdMember' => HouseholdRole.householdMember,
      'HouseholdGuest' => HouseholdRole.householdGuest,
      _ => HouseholdRole.unknown,
    };
  }

  /// Maps a typed [HouseholdRole] back to the persisted role-name string.
  /// [HouseholdRole.unknown] persists as `'Unknown'`; the originating
  /// custom role name from the server is not preserved through this
  /// bridge.
  static String? _encodeRole(HouseholdRole? role) {
    if (role == null) return null;
    return switch (role) {
      HouseholdRole.householdOwner => 'HouseholdOwner',
      HouseholdRole.householdAdmin => 'HouseholdAdmin',
      HouseholdRole.householdMember => 'HouseholdMember',
      HouseholdRole.householdGuest => 'HouseholdGuest',
      HouseholdRole.unknown => 'Unknown',
    };
  }
}
