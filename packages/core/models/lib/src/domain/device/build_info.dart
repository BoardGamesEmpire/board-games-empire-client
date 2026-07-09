import 'package:freezed_annotation/freezed_annotation.dart';

part 'build_info.freezed.dart';
part 'build_info.g.dart';

/// The client's own build metadata, read once at startup (#35).
///
/// The single source of truth for the client version: consumed by version
/// negotiation (#13, compared against the server's `minClientVersion` /
/// `maxClientVersion`), stamped into feedback reports (#69), and emitted
/// as `bgeClientVersion` in the #11 export bundle — hence
/// JSON-serializable. Semver *parsing/comparison* deliberately lives with
/// the negotiation policy in #13; this value exposes raw strings only.
/// Device/OS/environment fields are excluded (that is #69 territory).
@freezed
abstract class BuildInfo with _$BuildInfo {
  const factory BuildInfo({
    /// Semver version string (e.g. `1.2.3`), derived from the app
    /// pubspec `version:` on every platform (native manifests and web's
    /// generated `version.json` alike; lockstep tracked in #73).
    required String version,

    /// Platform build identifier. A [String], not an int: build numbers
    /// are not guaranteed numeric on every platform.
    required String buildNumber,

    /// Human-readable application name.
    required String appName,

    /// Platform package/bundle identifier.
    required String packageName,
  }) = _BuildInfo;

  factory BuildInfo.fromJson(Map<String, dynamic> json) =>
      _$BuildInfoFromJson(json);

  /// Degraded fallback registered when the platform read fails
  /// (`BuildInfoReader` never throws into bootstrap).
  ///
  /// `0.0.0` is semver-parseable and sorts oldest, so #13 fails *closed*
  /// on an unreadable version (treated as "needs update") instead of
  /// choking on an unparseable string. The name fields are legible
  /// placeholders rather than empty strings: the about screen and
  /// feedback reports render them directly, and a visible "Unknown …" is
  /// both friendlier than a blank and itself the signal that the
  /// platform read failed.
  static const BuildInfo unknown = BuildInfo(
    version: '0.0.0',
    buildNumber: '0',
    appName: 'Unknown App Name',
    packageName: 'Unknown Package Name',
  );
}
