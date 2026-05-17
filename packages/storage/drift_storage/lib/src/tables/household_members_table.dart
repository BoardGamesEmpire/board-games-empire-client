import 'package:drift/drift.dart';

import './household_table.dart';

@TableIndex(name: 'household_members_user_idx', columns: {#userId})
@TableIndex(
  name: 'household_members_household_user_unique_idx',
  columns: {#householdId, #userId},
  unique: true,
)
class HouseholdMembersTable extends Table {
  TextColumn get id => text()();
  TextColumn get userId => text()();
  TextColumn get householdId => text().references(HouseholdsTable, #id)();
  BoolColumn get showAllGames => boolean().withDefault(const Constant(true))();
  TextColumn get roleName => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'household_members';
}
