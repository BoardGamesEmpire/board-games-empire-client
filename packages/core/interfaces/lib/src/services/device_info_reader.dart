/// Reads what the platform can tell a feedback report about the device it
/// came from (#324): the operating system, and where the platform knows them,
/// the OS version or the browser.
///
/// Implementations live in the platform packages (`native_platform` /
/// `web_platform`) and are registered by the per-platform root module.
/// `runBgeApp` reads one once while composing the `FeedbackService`, and the
/// map becomes every report's `deviceInfo`.
///
/// Keys: `operatingSystem` (`TargetPlatform.name` spelling — `android`,
/// `iOS`, `macOS`, `windows`, `linux`, `fuchsia` — plus `unknown` on web),
/// `operatingSystemVersion`, `operatingSystemBuild` (Android, which reports a
/// build ID rather than a version), `browser` (`'<Name> <major>'`) and
/// `browserEngine`.
///
/// **Defensive contract: [read] never throws.** It runs on the boot path, so
/// any platform-read failure leaves that entry out rather than failing the
/// boot. An entry the platform cannot determine is **omitted, never
/// guessed**: a report silent about the browser is honest, and one naming the
/// wrong OS sends triage after the wrong platform.
abstract interface class DeviceInfoReader {
  /// The device entries the platform could determine; any it could not are
  /// left out.
  Map<String, String> read();
}
