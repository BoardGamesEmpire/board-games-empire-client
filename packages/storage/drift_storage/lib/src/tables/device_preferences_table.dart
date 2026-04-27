import 'package:drift/drift.dart';

/// Single-row table holding device-level preferences.
///
/// Always accessed via upsert with a fixed sentinel [id] = 'device'.
@DataClassName('DevicePreferencesData')
class DevicePreferencesTable extends Table {
  @override
  String get tableName => 'device_preferences';

  /// Fixed sentinel value. Always 'device'. Enforces single-row constraint.
  TextColumn get id => text()();

  IntColumn get maxMonitoredServers =>
      integer().named('max_monitored_servers').withDefault(const Constant(5))();

  IntColumn get backgroundingTimeoutDesktopSeconds => integer()
      .named('backgrounding_timeout_desktop_seconds')
      .withDefault(const Constant(900))();

  IntColumn get backgroundingTimeoutMobileSeconds => integer()
      .named('backgrounding_timeout_mobile_seconds')
      .withDefault(const Constant(300))();

  BoolColumn get batteryAwareTransitions => boolean()
      .named('battery_aware_transitions')
      .withDefault(const Constant(false))();

  DateTimeColumn get updatedAt => dateTime().named('updated_at')();

  @override
  Set<Column> get primaryKey => {id};
}

/// The fixed sentinel PK for the device preferences row.
const kDevicePreferencesId = 'device';
