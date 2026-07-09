import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Web [BuildInfoReader], backed by `package_info_plus` — which on web
/// reads Flutter's generated `version.json`, derived from the app pubspec
/// `version:` like the native manifests (#35). Wasm-safe (`js_interop`).
///
/// [packageInfoReader] is the injectable source seam for tests;
/// production uses [PackageInfo.fromPlatform].
///
/// Honors the [BuildInfoReader] fail-closed contract in both dimensions:
/// **never throws** — any source failure (missing or unreachable
/// `version.json`, fetch error) resolves to [BuildInfo.unknown] — and
/// **never hangs** — the read is bounded by [readTimeout], since a
/// wedged `version.json` fetch (no error, no completion) would otherwise
/// stall `createRootContainer` and the whole boot. The catch is
/// deliberately silent: the degraded value is itself the visible signal,
/// and `web_platform` carries no observability dependency to log
/// through.
class PackageInfoBuildInfoReader implements BuildInfoReader {
  PackageInfoBuildInfoReader({
    Future<PackageInfo> Function()? packageInfoReader,
    this.readTimeout = defaultReadTimeout,
  }) : _packageInfoReader = packageInfoReader ?? PackageInfo.fromPlatform;

  /// Default upper bound on the platform read: generous against a slow
  /// connection serving `version.json` (a same-origin static file,
  /// normally milliseconds) while still bounding a pathological hang on
  /// the boot hot path.
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
