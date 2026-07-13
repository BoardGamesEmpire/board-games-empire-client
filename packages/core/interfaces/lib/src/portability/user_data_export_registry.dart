import 'user_data_exporter.dart';

/// Root-scope collection of [UserDataExporter]s (#11).
///
/// Each feature package registers its exporter at composition time.
/// GetIt has no multibinding, so registration is explicit and mutable:
/// the concrete registry is registered once in the root container and
/// features append to it. Exporters are stateless and receive the
/// `ServerContext` at call time, so root-scoped registration is safe
/// across server switches.
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
