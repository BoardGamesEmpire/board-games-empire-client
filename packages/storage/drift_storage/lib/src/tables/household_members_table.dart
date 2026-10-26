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

  /// The member's account name, display name and avatar, as the household
  /// list embeds them (#304). All three are null on a row no hydrate has
  /// written yet, and the last two are also null for an account that has not
  /// set them.
  TextColumn get username => text().nullable()();
  TextColumn get displayName => text().nullable()();
  TextColumn get avatarUrl => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'household_members';
}
