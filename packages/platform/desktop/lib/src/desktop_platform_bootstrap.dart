import 'package:native_platform/native_platform.dart';

/// Desktop [NativePlatformBootstrap].
///
/// Identical to the shared native composition for the alpha scope; this is
/// the hook point for desktop-specific concerns as they land (window and
/// tray management, the orchestrator's desktop backgrounding policy already
/// keys off platform detection, deep-link registration via #10, BuildInfo
/// via #35).
class DesktopPlatformBootstrap extends NativePlatformBootstrap {
  DesktopPlatformBootstrap();
}
