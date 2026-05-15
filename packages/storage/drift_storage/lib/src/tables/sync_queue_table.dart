import 'package:drift/drift.dart';

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
  List<Index> get indexes => [
    Index(
      'sync_queue_status_idx',
      'CREATE INDEX sync_queue_status_idx '
          'ON sync_queue (status, created_at)',
    ),
  ];

  @override
  String get tableName => 'sync_queue';
}
