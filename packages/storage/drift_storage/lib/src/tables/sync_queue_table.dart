import 'package:drift/drift.dart';

@TableIndex(
  name: 'sync_queue_user_status_idx',
  columns: {#userId, #status, #createdAt},
)
class SyncQueueTable extends Table {
  TextColumn get id => text()();

  /// The server-assigned id of the user who enqueued this operation (#147).
  ///
  /// Stamped at enqueue time from the user-session scope that owns the
  /// writing repository, and filtered on by **every** read and write so a
  /// repository built for one user can never see or touch another user's
  /// rows. NOT NULL by design: an unattributed row is undrainable — there
  /// is no session whose authority could legitimately push it — so the
  /// column refuses to represent one. Legacy pre-#147 rows were dropped in
  /// the v2 → v3 migration rather than backfilled (a backfill from the
  /// migrating session would attribute rows that may not be theirs).
  TextColumn get userId => text()();

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
