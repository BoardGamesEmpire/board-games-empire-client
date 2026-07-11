import 'package:connectivity_platform/connectivity_platform.dart';
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
/// awaited [BuildInfoReader.read] maps to `@preResolve`; the lazy
/// [ConnectivityService] maps to `@lazySingleton`).
///
/// Contract (see `PlatformBootstrap.createRootContainer`): registrations
/// must be defensive — a recoverable platform-read failure registers a
/// degraded value rather than throwing into bootstrap. [BuildInfoReader]
/// carries that guarantee itself ([BuildInfo.unknown] on failure or
/// timeout; never throws, never hangs), [FileFeedbackSink] resolves
/// its directory lazily (no plugin call at registration), and
/// [ConnectivityService] is registered **lazily** — the
/// [ConnectivityPlusService] constructor touches the connectivity plugin
/// (subscription + eager check), so construction is deferred to first
/// resolution, keeping registration itself plugin-free. This seam adds
/// no guarding of its own: a violation propagates to
/// `createRootContainer`'s dispose-partial guard and from there to
/// `runBgeApp`'s belt-and-braces fallback.
///
/// Registrations: [BuildInfo] (resolved read, #35), the durable
/// [FeedbackSink] (#69), and the device-global [ConnectivityService]
/// (#9) — disposed via its [Disposable] conformance when the root
/// container tears down. The [FeedbackService] itself is composed and
/// registered by `runBgeApp` — it needs shell-side collaborators
/// (breadcrumb ring, locale, the transport resolver) that don't exist at
/// this altitude.
///
/// [buildInfoReader] and [connectivityFactory] are injectable for tests;
/// production uses the concrete [PackageInfoBuildInfoReader] and
/// [ConnectivityPlusService].
Future<void> registerNativeRootModule(
  DependencyContainer container, {
  BuildInfoReader? buildInfoReader,
  ConnectivityService Function()? connectivityFactory,
}) async {
  final reader = buildInfoReader ?? PackageInfoBuildInfoReader();
  container
    ..registerSingleton<BuildInfo>(await reader.read())
    ..registerSingleton<FeedbackSink>(FileFeedbackSink())
    ..registerLazySingleton<ConnectivityService>(
      connectivityFactory ?? ConnectivityPlusService.new,
      dispose: (service) async {
        if (service case final Disposable disposable) {
          await disposable.onDispose();
        }
      },
    );
}
