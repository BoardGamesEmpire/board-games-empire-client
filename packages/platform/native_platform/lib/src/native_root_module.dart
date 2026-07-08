import 'package:interfaces/orchestration.dart';

/// Registers the shared native (mobile + desktop) device-global services
/// into the root container (#72).
///
/// Shaped as a module function so the #61 injectable conversion —
/// per-package micropackage modules aggregated by the platform
/// composition root — is a mechanical swap: this function's body becomes
/// the generated init call, its registrations become annotations.
///
/// Near-empty in the #72 shell by design; #35 (`BuildInfo`) and #69
/// (`FeedbackService`) populate it.
///
/// Contract (see `PlatformBootstrap.createRootContainer`): registrations
/// must be defensive — a recoverable platform-read failure registers a
/// degraded value (e.g. `BuildInfo.unknown`) rather than throwing into
/// bootstrap.
Future<void> registerNativeRootModule(DependencyContainer container) async {
  // Intentionally empty (#72 shell). First registrations land with #35.
}
