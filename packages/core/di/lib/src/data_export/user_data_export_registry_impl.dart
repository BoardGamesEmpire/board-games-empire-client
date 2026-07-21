import 'package:interfaces/portability.dart';

/// Mutable root-scope [UserDataExportRegistry] (#11).
///
/// Registered once in the root container; each feature package appends
/// its exporter at composition time (GetIt has no multibinding, so
/// registration is explicit). Registration happens on the composition
/// path only — this class is not thread-safe and does not need to be.
class UserDataExportRegistryImpl implements UserDataExportRegistry {
  final List<UserDataExporter> _exporters = <UserDataExporter>[];
  final Set<String> _keys = <String>{};

  @override
  void register(UserDataExporter exporter) {
    if (!_keys.add(exporter.key)) {
      throw ArgumentError.value(
        exporter.key,
        'exporter.key',
        'An exporter with this key is already registered',
      );
    }
    _exporters.add(exporter);
  }

  @override
  List<UserDataExporter> get exporters => List.unmodifiable(_exporters);
}
