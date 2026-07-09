/// Shared native (mobile + desktop) composition root.
///
/// Composes the concrete storage and network packages into the
/// `PlatformBootstrap` contract consumed by `app_shell`: encrypted MetaDB,
/// meta repositories, the real `ServerContextFactory` (storage + network
/// installers), the `ServerOrchestrator`, and the device-global root
/// container (#72) with its registrations (`BuildInfo`, #35).
/// `mobile_platform` and `desktop_platform` wrap this and add their
/// platform-specific concerns.
library;

export 'src/build_info/package_info_build_info_reader.dart';
export 'src/native_platform_bootstrap.dart';
export 'src/native_root_module.dart';
