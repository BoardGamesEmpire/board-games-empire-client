/// The environment stamped onto a [FeedbackReport] at build time (#69).
///
/// Assembled at the composition root, where the pieces live: `appVersion`
/// comes from the root container's `BuildInfo` (#35), `platform`/`locale`
/// from Flutter-side providers, `deviceInfo` from a minimal no-plugin
/// probe. `observability` is a pure-Dart leaf with no `models` (hence no
/// `BuildInfo`) or Flutter dependency, so the value is injected as this
/// plain bundle rather than resolved here — the service stays testable
/// without any platform machinery.
class FeedbackEnvironment {
  const FeedbackEnvironment({
    required this.appVersion,
    required this.platform,
    required this.locale,
    this.deviceInfo = const <String, dynamic>{},
  });

  /// Submitting client app version (from `BuildInfo.version`, #35).
  final String appVersion;

  /// Submitting platform (e.g. `android`, `macos`, `web`).
  final String platform;

  /// BCP-47 locale (e.g. `en-US`).
  final String locale;

  /// Minimal device/environment context (no `device_info_plus` in alpha).
  final Map<String, dynamic> deviceInfo;
}
