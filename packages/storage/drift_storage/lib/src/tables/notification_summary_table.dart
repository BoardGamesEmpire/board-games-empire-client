import 'package:drift/drift.dart';

@DataClassName('NotificationSummaryData')
class NotificationSummaries extends Table {
  @override
  String get tableName => 'notification_summaries';

  TextColumn get id => text()();

  /// FK to server_configs.id (local CUID).
  TextColumn get localServerId => text().named('local_server_id')();

  /// Denormalized BGE server UUID for display without a join.
  TextColumn get bgeServerId => text().named('bge_server_id')();

  /// Denormalized server display name captured at time of receipt.
  TextColumn get serverDisplayName => text().named('server_display_name')();

  TextColumn get title => text()();
  TextColumn get body => text().nullable()();

  BoolColumn get isRead =>
      boolean().named('is_read').withDefault(const Constant(false))();

  /// Signals that the per-server context must activate for full detail.
  BoolColumn get requiresFullLoad => boolean()
      .named('requires_full_load')
      .withDefault(const Constant(false))();

  DateTimeColumn get receivedAt => dateTime().named('received_at')();
  DateTimeColumn get createdAt => dateTime().named('created_at')();

  @override
  Set<Column> get primaryKey => {id};
}
