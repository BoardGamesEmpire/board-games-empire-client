import 'package:connectivity_platform/connectivity_platform.dart';
import 'package:di/di.dart';
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
/// [BuildInfoReader.read] maps to `@preResolve`; the lazy
/// [ConnectivityService] maps to `@lazySingleton`).
/// Aggregation-by-import in this web composition root (rather than
/// injectable environments) is what keeps native modules out of web
/// builds at compile time, and vice versa. `connectivity_platform` is
/// the deliberate exception to the twin-package split: the plugin is
/// federated (js_interop on web), so one shared package serves both
/// composition roots without dependency bleed (#9 design decision 1).
///
/// Contract (see `PlatformBootstrap.createRootContainer`): registrations
/// must be defensive — a recoverable platform-read failure registers a
/// degraded value rather than throwing into bootstrap. [BuildInfoReader]
/// carries that guarantee itself ([BuildInfo.unknown] on failure or
/// timeout; never throws, never hangs), [MemoryFeedbackSink] is pure
/// RAM, and [ConnectivityService] is registered **lazily** — the
/// [ConnectivityPlusService] constructor touches the connectivity plugin
/// (subscription + eager check), so construction is deferred to first
/// resolution, keeping registration itself plugin-free. This seam adds
/// no guarding of its own: a violation propagates to
/// `createRootContainer`'s dispose-partial guard and from there to
/// `runBgeApp`'s belt-and-braces fallback.
///
/// Registrations: [BuildInfo] (read from Flutter's generated
/// `version.json`, #35), the **in-memory stand-in** [FeedbackSink] —
/// web has no durable storage layer until #63 (an approved-but-unsent
/// report is lost on reload; the prompt tells the user so) — the
/// device-global [ConnectivityService] (#9), disposed via its
/// [Disposable] conformance when the root container tears down, and the
/// #15 [PushNotificationService] null object
/// ([UnsupportedPushNotificationService]: `const`, pure, plugin-free).
/// On web the stub may be permanent — browser push is a go/no-go
/// investigation (#113). The [FeedbackService] itself is composed and
/// registered by `runBgeApp`.
///
/// [buildInfoReader] and [connectivityFactory] are injectable for tests;
/// production uses the concrete [PackageInfoBuildInfoReader] and
/// [ConnectivityPlusService].
Future<void> registerWebRootModule(
  DependencyContainer container, {
  BuildInfoReader? buildInfoReader,
  ConnectivityService Function()? connectivityFactory,
}) async {
  final reader = buildInfoReader ?? PackageInfoBuildInfoReader();
  container
    ..registerSingleton<BuildInfo>(await reader.read())
    ..registerSingleton<FeedbackSink>(MemoryFeedbackSink())
    ..registerLazySingleton<ConnectivityService>(
      connectivityFactory ?? ConnectivityPlusService.new,
      dispose: (service) async {
        if (service case final Disposable disposable) {
          await disposable.onDispose();
        }
      },
    )
    // #15 push interface stub. Possibly permanent on web (#113 decides).
    ..registerSingleton<PushNotificationService>(
      const UnsupportedPushNotificationService(),
    )
    // #36/#87: pure, stateless. Web registers no WellKnownClient —
    // same-origin means a server always exists, /server-add is
    // unreachable, and no web implementation exists; the negotiator is
    // registered anyway because the refresh-time re-check (#87) applies
    // to web's identity fetch during auth (#37).
    ..registerLazySingleton<VersionNegotiator>(VersionNegotiatorImpl.new);
}
