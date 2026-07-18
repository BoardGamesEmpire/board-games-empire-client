import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart';

import '../deep_links/deep_link_source.dart';

/// Initializes `HydratedBloc.storage`. Injectable so cubit tests can supply
/// a no-op or counting fake; production wiring builds the real
/// [HydratedStorage] from [PlatformBootstrap.hydratedStorageDirectory].
typedef HydratedStorageInitializer =
    Future<void> Function(PlatformBootstrap bootstrap);

/// Outcome of a successful [PlatformBootstrap.initialize] run.
class BootstrapResult {
  const BootstrapResult({
    required this.hasServer,
    this.orchestrator,
    this.activeServerScope,
  });

  /// Whether at least one BGE server is known to this device.
  ///
  /// Native platforms answer from the MetaDB server registry. Web always
  /// reports `true`: the browser can only ever talk to the origin in the
  /// address bar, so a "server" is present by construction.
  final bool hasServer;

  /// The initialized [ServerOrchestrator], or `null` on web.
  ///
  /// Web is single-server by construction (same-origin) and has no MetaDB,
  /// so it never constructs an orchestrator. Native platforms construct and
  /// [ServerOrchestrator.initialize] it inside
  /// [PlatformBootstrap.initialize].
  final ServerOrchestrator? orchestrator;

  /// The platform-neutral "which server is active" seam (#37) the shell
  /// provisions the auth bloc (and later per-server services) from.
  ///
  /// Native supplies `OrchestratorActiveServerScope` over [orchestrator].
  /// Web's single-origin implementation lands with #96; until then web
  /// returns `null` and the shell renders no auth subtree (the auth leg is
  /// not yet reachable on web).
  final ActiveServerScope? activeServerScope;
}

/// Per-platform composition root consumed by the shared shell.
///
/// Implementations live in `packages/platform/{mobile,desktop,web}` — the
/// one place per platform that knows how the concrete storage and network
/// packages fit together. The shell only knows this contract; concrete
/// dependencies (`drift_storage`, `dio_network`, `web_network`) never leak
/// into `app_shell`, which keeps web builds free of `dart:io`/`dart:ffi`
/// concretes and native builds free of web ones.
abstract interface class PlatformBootstrap {
  /// Builds and populates the **root container** — the app-scope,
  /// device-global [DependencyContainer] (#72).
  ///
  /// Called by `runBgeApp` exactly once per boot, *before* the global
  /// error hooks are installed and before [initialize]: device-global
  /// services (client version #35, feedback #69) must exist even when the
  /// failure-prone platform bootstrap never succeeds, so failed boots can
  /// still be reported with full context. Each call returns a freshly
  /// built container: a hot restart starts from clean state (no
  /// registrations carried across the restart) because implementations
  /// wrap their own `GetIt.asNewInstance()`, never `GetIt.instance`. It
  /// does not (and at this layer cannot) dispose a prior run's container
  /// on hot restart — `State.dispose` is not guaranteed to fire then, a
  /// universal Flutter constraint that also applies to the orchestrator.
  ///
  /// Implementations must keep their work **synchronous or fully
  /// awaited**: this runs before the global error hooks are installed and
  /// there is deliberately no Zone, so a *detached* async error escaping
  /// the awaited call would be uncaptured (`runBgeApp`'s guard only sees
  /// what the awaited future surfaces). A single awaited platform read
  /// (e.g. `PackageInfo.fromPlatform`, #35) satisfies this.
  ///
  /// **Must not throw.** A recoverable platform-read failure registers a
  /// degraded value (e.g. `BuildInfo.unknown`, #35) instead of failing
  /// the boot. `runBgeApp` additionally guards the call and boots on an
  /// empty fallback container if an implementation violates this — error
  /// capture is never coupled to root-container success. That fallback is
  /// intentionally empty (there is nothing platform-appropriate to seed it
  /// with at the shell layer), so consumers resolving from the root
  /// container on the failed-boot path must tolerate an absent
  /// registration — resolve-or-default, e.g. fall back to
  /// `BuildInfo.unknown` / a no-op reporter — rather than assume presence.
  ///
  /// Registration content is owned by the per-platform root module
  /// function (manual for now; converted to aggregated injectable
  /// micropackage modules by #61). Widget-tree exposure of the container
  /// is deliberately deferred (#72 decision): consumers today live on the
  /// bootstrap path, and the first widget consumer adds a thin provider
  /// when it actually needs one. Per-server contexts never see this
  /// container implicitly — root services reach them by explicit
  /// constructor injection at context construction (#38 isolation).
  Future<DependencyContainer> createRootContainer();

  /// Creates this platform's out-of-band deep-link source (#10), or
  /// returns null when the platform has no such channel.
  ///
  /// Native (mobile, desktop) returns an `app_links`-backed source that
  /// delivers `bge://` URLs — the launch link included. Web returns
  /// **null**: the browser can only navigate within the origin, the
  /// address-bar URL *is* the link, and `go_router`'s path URL strategy
  /// already consumes it directly; there is no second channel to adapt.
  ///
  /// Called at most once per boot by `runBgeApp`, before [initialize] —
  /// the underlying plugin must be instantiated early to capture the
  /// cold-start launch link. Callers own the resulting subscription
  /// lifecycle (via `DeepLinkHandler`); a null return simply means no
  /// handler is constructed.
  DeepLinkSource? createDeepLinkSource();

  /// Creates this platform's process-wide log sink (#100), attached to
  /// `Logger.root` by `ShellObservability` before anything else logs.
  ///
  /// The sink is deliberately "dumb": it renders and writes; the shell
  /// applies the build-mode console threshold upstream, so the sink never
  /// decides what to drop. Platform split: native returns a
  /// `developer.log` sink (DevTools + Logcat), desktop additionally a
  /// rotating file sink; web returns a `print` sink (a deployed web build
  /// has no DevTools channel). The concrete `dart:io` file rotation lives
  /// in `native_platform`, never in a web-compiled package.
  ///
  /// Called once per boot, synchronously, and safe *before*
  /// `WidgetsFlutterBinding.ensureInitialized()`: constructing the sink is
  /// pure; a file sink defers the directory lookup that needs the binding
  /// to its first write.
  LogSink createLogSink();

  /// Acquires the platform's app-global resources.
  ///
  /// Native: open the encrypted MetaDB, build the meta repositories,
  /// compose the real `ServerContextFactory` (storage + network installers),
  /// construct and initialize the [ServerOrchestrator], and wrap it in an
  /// `OrchestratorActiveServerScope` for the [BootstrapResult].
  ///
  /// Web: nothing to open — return
  /// `BootstrapResult(hasServer: true, orchestrator: null,
  /// activeServerScope: null)` until #96 supplies the single-origin scope.
  ///
  /// May throw (e.g. `DatabaseKeyError` when the meta key is lost). The
  /// shell surfaces failures as a retryable error state; it never reacts
  /// destructively on its own.
  Future<BootstrapResult> initialize();

  /// Whether [reset] is meaningful on this platform.
  ///
  /// `true` on native (a device-local MetaDB exists to delete), `false` on
  /// web. When `false`, the shell never offers the destructive recovery
  /// action, regardless of how many attempts have failed.
  bool get supportsReset;

  /// Destroys the device-local meta state so the next [initialize] starts
  /// clean: delete the meta encryption key **first**, then the meta
  /// database file and its companions (matching the key-before-file
  /// recovery ordering established in `StorageScopeInstaller`).
  ///
  /// Only invoked after repeated [initialize] failures **and** explicit
  /// user confirmation — never automatically. Implementations where
  /// [supportsReset] is `false` throw [UnsupportedError].
  Future<void> reset();

  /// Where `HydratedBloc` persists bloc state on this platform.
  ///
  /// Native resolves an application-support path (async);
  /// web returns [HydratedStorageDirectory.web].
  Future<HydratedStorageDirectory> hydratedStorageDirectory();
}
