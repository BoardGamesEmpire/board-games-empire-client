import 'package:drift/drift.dart';
import 'package:drift_storage/src/databases/meta_database.dart';
import 'package:drift_storage/src/tables/device_preferences_table.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

class DevicePreferencesRepositoryImpl implements DevicePreferencesRepository {
  DevicePreferencesRepositoryImpl(this._database);

  final MetaDatabase _database;

  @override
  Future<DevicePreferences> get() async {
    final row = await (_database.select(
      _database.devicePreferencesTable,
    )..where((t) => t.id.equals(kDevicePreferencesId))).getSingleOrNull();
    return row != null ? _mapToModel(row) : const DevicePreferences();
  }

  @override
  Future<void> save(DevicePreferences preferences) async {
    await _database
        .into(_database.devicePreferencesTable)
        .insertOnConflictUpdate(
          DevicePreferencesTableCompanion.insert(
            id: kDevicePreferencesId,
            maxMonitoredServers: Value(preferences.maxMonitoredServers),
            backgroundingTimeoutDesktopSeconds: Value(
              preferences.backgroundingTimeoutDesktopSeconds,
            ),
            backgroundingTimeoutMobileSeconds: Value(
              preferences.backgroundingTimeoutMobileSeconds,
            ),
            batteryAwareTransitions: Value(preferences.batteryAwareTransitions),
            updatedAt: DateTime.now().toUtc(),
          ),
        );
  }

  @override
  Stream<DevicePreferences> watch() =>
      (_database.select(_database.devicePreferencesTable)
            ..where((t) => t.id.equals(kDevicePreferencesId)))
          .watchSingleOrNull()
          .map(
            (row) => row != null ? _mapToModel(row) : const DevicePreferences(),
          );

  DevicePreferences _mapToModel(
    DevicePreferencesData data,
  ) => DevicePreferences(
    maxMonitoredServers: data.maxMonitoredServers,
    backgroundingTimeoutDesktopSeconds: data.backgroundingTimeoutDesktopSeconds,
    backgroundingTimeoutMobileSeconds: data.backgroundingTimeoutMobileSeconds,
    batteryAwareTransitions: data.batteryAwareTransitions,
  );
}
