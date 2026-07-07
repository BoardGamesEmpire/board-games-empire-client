/// Shared native (mobile + desktop) composition root.
///
/// Composes the concrete storage and network packages into the
/// `PlatformBootstrap` contract consumed by `app_shell`: encrypted MetaDB,
/// meta repositories, the real `ServerContextFactory` (storage + network
/// installers), and the `ServerOrchestrator`. `mobile_platform` and
/// `desktop_platform` wrap this and add their platform-specific concerns.
library;

export 'src/native_platform_bootstrap.dart';
