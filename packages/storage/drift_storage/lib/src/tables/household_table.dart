import 'package:drift/drift.dart';

class HouseholdsTable extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get description => text().nullable()();
  TextColumn get image => text().nullable()();

  /// True when this row has local changes not yet synced to the server.
  BoolColumn get isDirty => boolean().withDefault(const Constant(false))();

  /// True when this row was created offline / optimistically and has not
  /// yet been confirmed by the server. Set on the optimistic create row
  /// (#39) and cleared on reconcile once the server assigns the id.
  BoolColumn get isLocalOnly => boolean().withDefault(const Constant(false))();

  DateTimeColumn get deletedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'households';
}
