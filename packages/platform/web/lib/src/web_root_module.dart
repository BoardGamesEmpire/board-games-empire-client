import 'package:interfaces/orchestration.dart';

/// Registers the web device-global services into the root container (#72).
///
/// Shaped as a module function so the #61 injectable conversion —
/// per-package micropackage modules aggregated by the platform
/// composition root — is a mechanical swap. Aggregation-by-import in this
/// web composition root (rather than injectable environments) is what
/// keeps native modules out of web builds at compile time, and vice
/// versa.
///
/// Near-empty in the #72 shell by design; #35 populates it (the web
/// client-version read from Flutter's generated `version.json`).
///
/// Contract (see `PlatformBootstrap.createRootContainer`): registrations
/// must be defensive — a recoverable platform-read failure registers a
/// degraded value (e.g. `BuildInfo.unknown`) rather than throwing into
/// bootstrap.
Future<void> registerWebRootModule(DependencyContainer container) async {
  // Intentionally empty (#72 shell). First registrations land with #35.
}
