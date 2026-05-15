import 'package:drift/drift.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../databases/server_database.dart';

class HouseholdRepositoryImpl implements HouseholdRepository {
  const HouseholdRepositoryImpl(this._db);

  final ServerDatabase _db;

  @override
  Future<List<Household>> getHouseholds() async {
    final rows = await (_db.select(
      _db.householdsTable,
    )..where((t) => t.deletedAt.isNull())).get();
    return rows.map(_mapHousehold).toList();
  }

  @override
  Future<Household?> getHousehold(String id) async {
    final row = await (_db.select(
      _db.householdsTable,
    )..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _mapHousehold(row);
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
    // currentUserId is resolved at the caller level via DI
    // For the interface, we match on householdId only — callers filter by userId
    return null; // TODO: inject currentUserId in constructor, same pattern as GameCollectionRepository
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
  Stream<List<Household>> watchHouseholds() =>
      (_db.select(_db.householdsTable)..where((t) => t.deletedAt.isNull()))
          .watch()
          .map((rows) => rows.map(_mapHousehold).toList());

  @override
  Stream<List<HouseholdMember>> watchMembers(String householdId) =>
      (_db.select(_db.householdMembersTable)
            ..where((t) => t.householdId.equals(householdId)))
          .watch()
          .map((rows) => rows.map(_mapMember).toList());

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
    roleName: row.roleName,
    createdAt: row.createdAt,
    updatedAt: row.updatedAt,
  );

  HouseholdMembersTableCompanion _memberToCompanion(HouseholdMember m) =>
      HouseholdMembersTableCompanion.insert(
        id: m.id,
        userId: m.userId,
        householdId: m.householdId,
        showAllGames: Value(m.showAllGames),
        roleName: Value(m.roleName),
        createdAt: m.createdAt,
        updatedAt: m.updatedAt,
      );
}
