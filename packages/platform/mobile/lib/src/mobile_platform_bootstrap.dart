import 'package:native_platform/native_platform.dart';

/// Mobile [NativePlatformBootstrap].
///
/// Identical to the shared native composition for the alpha scope; this is
/// the hook point for mobile-specific concerns as they land (connectivity
/// monitoring, device info for feedback reports, deep-link manifests via
/// #10, BuildInfo via #35).
class MobilePlatformBootstrap extends NativePlatformBootstrap {
  MobilePlatformBootstrap();
}
