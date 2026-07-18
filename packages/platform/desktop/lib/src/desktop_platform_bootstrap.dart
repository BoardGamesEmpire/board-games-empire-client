import 'package:native_platform/native_platform.dart';

/// Desktop [NativePlatformBootstrap].
///
/// Identical to the shared native composition for the alpha scope, save
/// for enabling the rotating file log (#100); this is the hook point for
/// desktop-specific concerns as they land (window and tray management, the
/// orchestrator's desktop backgrounding policy already keys off platform
/// detection, deep-link registration via #10, BuildInfo via #35).
class DesktopPlatformBootstrap extends NativePlatformBootstrap {
  DesktopPlatformBootstrap();

  /// Desktop persists logs to a rotating file in addition to the DevTools
  /// console (#100) — a self-hoster can tail or attach it to a bug report
  /// without triggering the in-app feedback flow. Mobile stays Logcat-only
  /// (the base default).
  @override
  bool get enableFileLog => true;
}
