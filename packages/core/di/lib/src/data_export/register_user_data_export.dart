import 'package:di/src/data_export/user_data_export_bundler.dart';
import 'package:di/src/data_export/user_data_export_registry_impl.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/portability.dart';
import 'package:models/domain.dart';

/// Registers the user-data export registry and bundler (#48) on
/// [container].
///
/// One [UserDataExportRegistryImpl] takes every exporter in [exporters], in
/// list order, and is registered as the [UserDataExportRegistry] singleton.
/// [UserDataExportBundler] is registered lazily as a singleton, over that
/// registry and the container's [BuildInfo]. Both the native and the web
/// root module call this, so the two platforms offer the same export
/// spine.
///
/// [BuildInfo] is read when the bundler is first resolved, so the container
/// must have one by then; it need not have it at this call.
void registerUserDataExport(
  DependencyContainer container, {
  required List<UserDataExporter> exporters,
}) {
  final registry = UserDataExportRegistryImpl();
  exporters.forEach(registry.register);
  container
    ..registerSingleton<UserDataExportRegistry>(registry)
    ..registerLazySingleton<UserDataExportBundler>(
      () => UserDataExportBundler(
        registry: container.get<UserDataExportRegistry>(),
        buildInfo: container.get<BuildInfo>(),
      ),
    );
}
