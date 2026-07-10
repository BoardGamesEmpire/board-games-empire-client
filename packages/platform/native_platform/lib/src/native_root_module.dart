import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

import 'build_info/package_info_build_info_reader.dart';
import 'feedback/file_feedback_sink.dart';

/// Registers the shared native (mobile + desktop) device-global services
/// into the root container (#72).
///
/// Shaped as a module function so the #61 injectable conversion —
/// per-package micropackage modules aggregated by the platform
/// composition root — is a mechanical swap: this function's body becomes
/// the generated init call, its registrations become annotations (the
/// awaited [BuildInfoReader.read] maps to `@preResolve`).
///
/// Contract (see `PlatformBootstrap.createRootContainer`): registrations
/// must be defensive — a recoverable platform-read failure registers a
/// degraded value rather than throwing into bootstrap. [BuildInfoReader]
/// carries that guarantee itself ([BuildInfo.unknown] on failure or
/// timeout; never throws, never hangs), and [FileFeedbackSink] resolves
/// its directory lazily (no plugin call at registration), so the default
/// production path — fresh container, single pass, concrete
/// collaborators — cannot fail the boot. This seam adds no guarding of
/// its own: a violation propagates to `createRootContainer`'s
/// dispose-partial guard and from there to `runBgeApp`'s belt-and-braces
/// fallback.
///
/// Registrations (#69): [BuildInfo] (resolved read) and the durable
/// [FeedbackSink]. The [FeedbackService] itself is composed and
/// registered by `runBgeApp` — it needs shell-side collaborators
/// (breadcrumb ring, locale, the transport resolver) that don't exist at
/// this altitude.
///
/// [buildInfoReader] is injectable for tests; production uses the
/// concrete [PackageInfoBuildInfoReader].
Future<void> registerNativeRootModule(
  DependencyContainer container, {
  BuildInfoReader? buildInfoReader,
}) async {
  final reader = buildInfoReader ?? PackageInfoBuildInfoReader();
  container
    ..registerSingleton<BuildInfo>(await reader.read())
    ..registerSingleton<FeedbackSink>(FileFeedbackSink());
}
