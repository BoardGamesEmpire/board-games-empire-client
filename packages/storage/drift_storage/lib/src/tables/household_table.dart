import 'package:drift/drift.dart';

class HouseholdsTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();
  TextColumn get image => text().nullable()();
  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'households';
}

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
  List<Index> get indexes => [
    Index(
      'household_members_user_idx',
      'CREATE INDEX household_members_user_idx '
          'ON household_members (user_id)',
    ),
    // Renamed from `household_members_household_idx` (the old name did
    // not convey the (household_id, user_id) uniqueness constraint).
    // Schema v2 migration drops the old name and creates this one.
    Index(
      'household_members_household_user_unique_idx',
      'CREATE UNIQUE INDEX '
          'household_members_household_user_unique_idx '
          'ON household_members (household_id, user_id)',
    ),
  ];

  @override
  String get tableName => 'household_members';
}
