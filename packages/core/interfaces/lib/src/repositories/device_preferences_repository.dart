import 'package:models/domain.dart';

/// Repository for device-level preferences governing multi-server behaviour.
///
/// There is always exactly one [DevicePreferences] row. [get] returns defaults
/// if the row does not yet exist. [save] upserts.
abstract class DevicePreferencesRepository {
  /// Returns current device preferences, or [DevicePreferences()] defaults
  /// if no preferences have been saved yet.
  Future<DevicePreferences> get();

  /// Persists device preferences. Creates the row on first call, replaces on
  /// subsequent calls.
  Future<void> save(DevicePreferences preferences);

  /// Stream of device preference changes.
  Stream<DevicePreferences> watch();
}
