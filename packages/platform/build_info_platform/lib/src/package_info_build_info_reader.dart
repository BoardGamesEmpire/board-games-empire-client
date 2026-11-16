import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// The [BuildInfoReader] for native and web alike, backed by
/// `package_info_plus` (#35). The plugin is federated, so one class serves
/// both composition roots (#196). Its source is the Android manifest or
/// macOS bundle on native, and Flutter's generated `version.json` on web
/// (wasm-safe, through `js_interop`). Both are derived from the app
/// pubspec's `version:`.
///
/// `packageInfoReader` is the injectable source seam for tests (the same
/// constructor-injection shape as `ConnectivityPlusService`); production
/// uses [PackageInfo.fromPlatform].
///
/// Honors the [BuildInfoReader] fail-closed contract in both dimensions:
/// **never throws** — any source failure (a missing plugin, a channel
/// error, a missing or unreachable `version.json`) resolves to
/// [BuildInfo.unknown] — and **never hangs** — the read is bounded by
/// [readTimeout]. The read blocks `createRootContainer` on the boot hot
/// path, so a wedged method-channel read or `version.json` fetch (no
/// error, no completion) must degrade, not stall the boot. The catch is
/// deliberately silent: this package has no observability dependency to
/// log through, and the degraded value is itself the visible signal
/// (feedback reports and the about screen render "Unknown …" directly).
class PackageInfoBuildInfoReader implements BuildInfoReader {
  PackageInfoBuildInfoReader({
    Future<PackageInfo> Function()? packageInfoReader,
    this.readTimeout = defaultReadTimeout,
  }) : _packageInfoReader = packageInfoReader ?? PackageInfo.fromPlatform;

  /// Default upper bound on the platform read: generous against a slow
  /// device or a slow connection serving `version.json` (a local
  /// method-channel call or a same-origin static file, normally
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
