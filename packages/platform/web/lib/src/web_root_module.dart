import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

import 'build_info/package_info_build_info_reader.dart';

/// Registers the web device-global services into the root container
/// (#72).
///
/// Shaped as a module function so the #61 injectable conversion —
/// per-package micropackage modules aggregated by the platform
/// composition root — is a mechanical swap (the awaited
/// [BuildInfoReader.read] maps to `@preResolve`). Aggregation-by-import
/// in this web composition root (rather than injectable environments) is
/// what keeps native modules out of web builds at compile time, and vice
/// versa.
///
/// Contract (see `PlatformBootstrap.createRootContainer`): registrations
/// must be defensive — a recoverable platform-read failure registers a
/// degraded value rather than throwing into bootstrap. [BuildInfoReader]
/// carries that guarantee itself ([BuildInfo.unknown] on failure or
/// timeout; never throws, never hangs), and [MemoryFeedbackSink] is pure
/// RAM, so the default production path cannot fail the boot. This seam
/// adds no guarding of its own: a violation propagates to
/// `createRootContainer`'s dispose-partial guard and from there to
/// `runBgeApp`'s belt-and-braces fallback.
///
/// Registrations (#69): [BuildInfo] (read from Flutter's generated
/// `version.json`) and the **in-memory stand-in** [FeedbackSink] — web
/// has no durable storage layer until #63 (an approved-but-unsent report
/// is lost on reload; the prompt tells the user so). The
/// [FeedbackService] itself is composed and registered by `runBgeApp`.
///
/// [buildInfoReader] is injectable for tests; production uses the
/// concrete [PackageInfoBuildInfoReader].
Future<void> registerWebRootModule(
  DependencyContainer container, {
  BuildInfoReader? buildInfoReader,
}) async {
  final reader = buildInfoReader ?? PackageInfoBuildInfoReader();
  container
    ..registerSingleton<BuildInfo>(await reader.read())
    ..registerSingleton<FeedbackSink>(MemoryFeedbackSink());
}
