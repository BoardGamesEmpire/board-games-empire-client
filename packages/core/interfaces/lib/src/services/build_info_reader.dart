import 'package:models/domain.dart';

/// Reads the client's own [BuildInfo] from the platform (#35).
///
/// The implementation lives in `build_info_platform`, backed by
/// `package_info_plus` and shared by native and web, and is consumed by
/// the per-platform root-module registration: the value is read once during
/// `PlatformBootstrap.createRootContainer` and registered as a singleton
/// — the manual analog of injectable's `@preResolve` (#61).
///
/// **Defensive contract: [read] never throws and never hangs.** Any
/// platform-read failure resolves to [BuildInfo.unknown], and the read
/// must be time-bounded — it blocks `createRootContainer` on the boot
/// hot path, so a wedged platform source (no error, no completion) must
/// degrade to [BuildInfo.unknown] rather than stall the boot. Root-
/// container population can therefore never fail or hang the boot on
/// account of build metadata (see
/// `PlatformBootstrap.createRootContainer`'s no-throw contract). The
/// degraded value is itself the failure signal — it surfaces legibly in
/// feedback reports and the about screen.
abstract interface class BuildInfoReader {
  /// Reads the client's build metadata, resolving to [BuildInfo.unknown]
  /// on any failure.
  Future<BuildInfo> read();
}
