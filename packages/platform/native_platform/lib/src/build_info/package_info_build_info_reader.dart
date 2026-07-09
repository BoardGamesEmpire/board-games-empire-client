import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Native (mobile + desktop) [BuildInfoReader], backed by
/// `package_info_plus` — Android manifest / macOS bundle values, both
/// derived from the app pubspec `version:` (#35).
///
/// [packageInfoReader] is the injectable source seam for tests (the same
/// constructor-injection shape `SecureStorageEncryptionKeyService` uses
/// for its storage); production uses [PackageInfo.fromPlatform].
///
/// Honors the [BuildInfoReader] fail-closed contract in both dimensions:
/// **never throws** — any source failure (missing plugin, channel error)
/// resolves to [BuildInfo.unknown] — and **never hangs** — the read is
/// bounded by [readTimeout], since it blocks `createRootContainer` on
/// the boot hot path and a wedged platform read must degrade, not stall
/// the boot. The catch is deliberately silent: the degraded value is
/// itself the visible signal (feedback reports and the about screen
/// render "Unknown …" directly), and logging here would force an
/// observability dependency the web twin of this class cannot mirror.
class PackageInfoBuildInfoReader implements BuildInfoReader {
  PackageInfoBuildInfoReader({
    Future<PackageInfo> Function()? packageInfoReader,
    this.readTimeout = defaultReadTimeout,
  }) : _packageInfoReader = packageInfoReader ?? PackageInfo.fromPlatform;

  /// Default upper bound on the platform read: generous against a slow
  /// device (the read is a local method-channel call, normally
  /// milliseconds) while still bounding a pathological hang on the boot
  /// hot path.
  static const Duration defaultReadTimeout = Duration(seconds: 5);

  /// Upper bound on the platform read; on expiry the read resolves to
  /// [BuildInfo.unknown]. Injectable so tests don't wall-clock.
  final Duration readTimeout;

  final Future<PackageInfo> Function() _packageInfoReader;

  @override
  Future<BuildInfo> read() async {
    try {
      final info = await _packageInfoReader().timeout(readTimeout);
      return BuildInfo(
        version: info.version,
        buildNumber: info.buildNumber,
        appName: info.appName,
        packageName: info.packageName,
      );
    } on Object {
      return BuildInfo.unknown;
    }
  }
}
