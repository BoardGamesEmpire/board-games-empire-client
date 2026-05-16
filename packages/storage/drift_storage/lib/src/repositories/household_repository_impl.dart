import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../databases/server_database.dart';

/// Read cache + queued-write implementation of [HouseholdRepository].
///
/// Scoped to a current user via [currentUserId]: list and watch reads
/// inner-join `household_members` so the caller only ever sees
/// households they belong to. Single-household lookup likewise returns
/// null when the current user is not a member, regardless of whether
/// the household exists in the local cache.
///
/// Member-list reads (`getMembers`, `watchMembers`) intentionally do
/// NOT re-filter by current user — once the household is visible, the
/// caller can see all co-members. The visibility gate lives at the
/// household level.
///
/// The cache writers (`cacheHousehold`, `cacheMember`, `cacheMembers`)
/// are user-agnostic: the server has already done auth filtering on
/// the response payload it sent us.
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
  Future<Household?> getHousehold(String id) async {
    final query = _db.select(_db.householdsTable).join([
      innerJoin(
        _db.householdMembersTable,
        _db.householdMembersTable.householdId.equalsExp(
              _db.householdsTable.id,
            ) &
            _db.householdMembersTable.userId.equals(_userId),
      ),
    ])..where(_db.householdsTable.id.equals(id));

    final row = await query.getSingleOrNull();
    return row == null
        ? null
        : _mapHousehold(row.readTable(_db.householdsTable));
  }

  @override
  Future<List<HouseholdMember>> getMembers(String householdId) async {
    final rows = await (_db.select(
      _db.householdMembersTable,
    )..where((t) => t.householdId.equals(householdId))).get();
    return rows.map(_mapMember).toList();
  }

  @override
  Future<HouseholdMember?> getCurrentUserMember(String householdId) async {
    final row =
        await (_db.select(_db.householdMembersTable)..where(
              (t) =>
                  t.householdId.equals(householdId) &
                  t.userId.equals(_userId),
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
  Stream<List<HouseholdMember>> watchMembers(String householdId) =>
      (_db.select(_db.householdMembersTable)
            ..where((t) => t.householdId.equals(householdId)))
          .watch()
          .map((rows) => rows.map(_mapMember).toList());

  // ── Mappers ────────────────────────────────────────────────────────────────

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
