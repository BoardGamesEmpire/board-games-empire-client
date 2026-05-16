import 'package:drift/drift.dart';

@TableIndex(name: 'sync_queue_status_idx', columns: {#status, #createdAt})
class SyncQueueTable extends Table {
  TextColumn get id => text()();

  /// Serialised [SyncOperation] JSON.
  TextColumn get payload => text()();

  /// [SyncStatus] enum name.
  TextColumn get status => text().withDefault(const Constant('pending'))();

  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get lastAttemptAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  String get tableName => 'sync_queue';
}
