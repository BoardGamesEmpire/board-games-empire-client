import 'package:cuid2/cuid2.dart';
import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
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
/// ## Scope: create + cache-writers
///
/// [create] is the one user-initiated mutation (P4, #39): it writes an
/// optimistic household + a synthesized owner member row and enqueues a
/// `CreateHouseholdOperation`, all in a single transaction, then
/// [reconcileCreatedHousehold] applies the server's confirmed row. The
/// remaining household mutations (`leaveHousehold`, `removeMember`,
/// `transferOwnership`, …) are deferred to the membership work (#122).
/// The "cache-writer" methods ([cacheHousehold], [cacheMember],
/// [cacheMembers]) are server-driven populators that accept payloads the
/// server already auth-filtered.
///
/// The [Household.isDirty] / [Household.isLocalOnly] columns are set on
/// the optimistic [create] row and cleared by [reconcileCreatedHousehold]
/// once the server confirms; server-sourced cache-writer rows carry them
/// as `false`.
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
  /// [syncQueue] MUST be backed by the same [db] instance for [create]'s
  /// "one transaction" guarantee to hold: the enqueue runs inside
  /// `db.transaction(...)` and only joins that transaction when it writes to
  /// the same database. `HouseholdScopeInstaller` wires it this way — a
  /// `SyncQueueRepositoryImpl` over this scope's `ServerDatabase`. A
  /// [SyncQueueRepository] over a *different* database would silently commit
  /// the enqueue outside the transaction (optimistic rows and their queued op
  /// could then diverge on partial failure), and no test would catch it.
  HouseholdRepositoryImpl({
    required ServerDatabase db,
    required String currentUserId,
    required SyncQueueRepository syncQueue,
    required ClockService clock,
  }) : _db = db,
       _userId = currentUserId,
       _syncQueue = syncQueue,
       _clock = clock;

  final ServerDatabase _db;
  final String _userId;
  final SyncQueueRepository _syncQueue;

  /// Server-corrected time source (#12). Timestamps this repository
  /// produces ([create]'s fresh `createdAt` / `updatedAt`) come from
  /// [ClockService.nowUtc], never `DateTime.now()`, staying consistent
  /// with the sync-queue and collection timestamps against the same
  /// server.
  final ClockService _clock;

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
            isDirty: Value(household.isDirty),
            isLocalOnly: Value(household.isLocalOnly),
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

  // ── Mutations (P4, #39) ──────────────────────────────────────────────────────────

  @override
  Future<({Household household, String syncQueueId})> create({
    required String name,
    String? description,
    String? image,
    String? language,
    String? visibility,
  }) async {
    // Validate BEFORE opening the transaction so the cache and the sync
    // queue stay untouched on bad input.
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'must not be blank');
    }

    return _db.transaction(() async {
      final now = _clock.nowUtc();
      // cuid2 id — matches the backend's id format. The backend's create
      // DTO strips client ids before Prisma, so a different canonical id
      // comes back and [reconcileCreatedHousehold] migrates this row onto
      // it. This localId is the sole correlation handle for that reconcile
      // (a household has no natural business key).
      final localId = cuid();

      // Optimistic household row.
      await _db
          .into(_db.householdsTable)
          .insert(
            HouseholdsTableCompanion.insert(
              id: localId,
              name: trimmedName,
              description: Value(description),
              image: Value(image),
              isDirty: const Value(true),
              isLocalOnly: const Value(true),
              createdAt: now,
              updatedAt: now,
            ),
          );

      // Synthesized owner member so the read gate surfaces the household
      // immediately. The server makes the creator a `HouseholdOwner` but
      // doesn't return the member row; this row's id is client-generated
      // and reconciled later by the membership sync (#122).
      await _db
          .into(_db.householdMembersTable)
          .insert(
            HouseholdMembersTableCompanion.insert(
              id: cuid(),
              userId: _userId,
              householdId: localId,
              roleName: Value(_encodeRole(HouseholdRole.householdOwner)),
              createdAt: now,
              updatedAt: now,
            ),
          );

      // Durable create op. If this throws, the writes above roll back.
      final entry = await _syncQueue.enqueue(
        CreateHouseholdOperation(
          localId: localId,
          name: trimmedName,
          description: description,
          image: image,
          language: language,
          visibility: visibility,
        ),
      );

      final row = await (_db.select(
        _db.householdsTable,
      )..where((t) => t.id.equals(localId))).getSingle();
      return (household: _mapHousehold(row), syncQueueId: entry.id);
    });
  }

  @override
  Future<void> reconcileCreatedHousehold(
    Household serverHousehold, {
    required String localId,
    String? completedSyncQueueId,
  }) async {
    return _db.transaction(() async {
      // 1. Upsert the server-confirmed household (canonical id, flags
      //    cleared). Done first so the members FK target exists before
      //    the re-point below (FK enforcement is on).
      await cacheHousehold(
        serverHousehold.copyWith(isDirty: false, isLocalOnly: false),
      );

      // 2. Server-assigned id path: migrate the synthesized owner member
      //    row(s) onto the canonical id, then drop the stale optimistic
      //    household row. The (householdId, userId) unique index can't
      //    collide — the canonical id is brand new.
      if (localId != serverHousehold.id) {
        await (_db.update(
          _db.householdMembersTable,
        )..where((t) => t.householdId.equals(localId))).write(
          HouseholdMembersTableCompanion(
            householdId: Value(serverHousehold.id),
          ),
        );
        await (_db.delete(
          _db.householdsTable,
        )..where((t) => t.id.equals(localId))).go();
      }

      // 3. Close the queued op in the same transaction, if the caller
      //    knows which one it was.
      if (completedSyncQueueId != null) {
        await _syncQueue.markCompleted(completedSyncQueueId);
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
    isDirty: row.isDirty,
    isLocalOnly: row.isLocalOnly,
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
