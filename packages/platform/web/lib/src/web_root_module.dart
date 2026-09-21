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
/// RAM and the durable [feedbackSink] is opened by the caller, which
/// degrades to that stand-in rather than handing a throw to this seam, and
/// [ConnectivityService] is registered **lazily** — the
/// [ConnectivityPlusService] constructor touches the connectivity plugin
/// (subscription + eager check), so construction is deferred to first
/// resolution, keeping registration itself plugin-free. This seam adds
/// no guarding of its own: a violation propagates to
/// `createRootContainer`'s dispose-partial guard and from there to
/// `runBgeApp`'s belt-and-braces fallback.
///
/// Registrations: [BuildInfo] (read from Flutter's generated
/// `version.json`, #35), the [FeedbackSink] — the durable IndexedDB sink
/// when [feedbackSink] supplies one, and the in-memory stand-in otherwise
/// (#292). The durable sink cannot be built here: it reaches
/// `dart:js_interop`, and this library is on the VM-compilable side of the
/// package split, so the browser-only composition root opens it and passes
/// it in. A caller that passes nothing — every VM test, and the storage-less
/// bootstrap — gets RAM, and an approved-but-unsent report is then lost on
/// reload. The device-global [ConnectivityService] (#9), disposed via its
/// [Disposable] conformance when the root container tears down, and the
/// #15 [PushNotificationService] null object
/// ([UnsupportedPushNotificationService]: `const`, pure, plugin-free).
/// On web the stub may be permanent — browser push is a go/no-go
/// investigation (#113). The [FeedbackService] itself is composed and
/// registered by `runBgeApp`.
///
/// [buildInfoReader] and [connectivityFactory] are injectable for tests;
/// production uses the concrete [PackageInfoBuildInfoReader] and
/// [ConnectivityPlusService]. [feedbackSink] is a **composition** seam
/// rather than a test one — it is how the browser-only half supplies a sink
/// this library cannot name.
///
/// [feedbackSink] is a *future* rather than a value so the two bootstrap-time
/// platform reads overlap. Both are bounded — [BuildInfoReader] by its own
/// read timeout, the sink's open by its — and they share no state, so taking
/// them in sequence would have stacked one worst case on the other in front of
/// a blank page. The caller starts the open before calling, both are then in
/// flight at once, and awaiting them one after the other costs the longer of
/// the two rather than the sum.
Future<void> registerWebRootModule(
  DependencyContainer container, {
  BuildInfoReader? buildInfoReader,
  ConnectivityService Function()? connectivityFactory,
  Future<FeedbackSink?>? feedbackSink,
}) async {
  final reader = buildInfoReader ?? PackageInfoBuildInfoReader();
  // Resolved before the read is awaited, so a caller's in-flight open is not
  // held up behind it.
  final pendingSink = feedbackSink ?? Future<FeedbackSink?>.value();
  container
    ..registerSingleton<BuildInfo>(await reader.read())
    ..registerSingleton<FeedbackSink>(
      await pendingSink ?? MemoryFeedbackSink(),
      dispose: (sink) async {
        // The durable sink holds an open IndexedDB connection; the stand-in
        // holds nothing. Same conformance check as ConnectivityService below,
        // so neither needs the module to know which it got.
        if (sink case final Disposable disposable) {
          await disposable.onDispose();
        }
      },
    )
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
