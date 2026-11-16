import 'package:interfaces/src/portability/user_data_exporter.dart';

/// Root-scope collection of [UserDataExporter]s (#11).
///
/// Filled at composition time: each composition root passes its
/// exporters to `registerUserDataExport`, which registers them here in
/// list order and registers the registry once in the root container.
/// GetIt has no multibinding, so the list is explicit. Exporters are
/// stateless and receive the `ActiveServer` at call time, so root-scoped
/// registration is safe across server switches.
abstract interface class UserDataExportRegistry {
  /// Registers [exporter].
  ///
  /// Throws [ArgumentError] if an exporter with the same
  /// [UserDataExporter.key] is already registered — a duplicate key
  /// would silently clobber a category in the bundled output.
  void register(UserDataExporter exporter);

  /// The registered exporters, in registration order.
  ///
  /// The returned list is an unmodifiable snapshot; mutating it throws.
  List<UserDataExporter> get exporters;
}
