import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';

/// Initializes `HydratedBloc.storage`. Injectable so cubit tests can supply
/// a no-op or counting fake; production wiring builds the real
/// [HydratedStorage] from [PlatformBootstrap.hydratedStorageDirectory].
typedef HydratedStorageInitializer =
    Future<void> Function(PlatformBootstrap bootstrap);

/// Outcome of a successful [PlatformBootstrap.initialize] run.
class BootstrapResult {
  const BootstrapResult({required this.hasServer, this.orchestrator});

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

  /// Acquires the platform's app-global resources.
  ///
  /// Native: open the encrypted MetaDB, build the meta repositories,
  /// compose the real `ServerContextFactory` (storage + network installers),
  /// construct and initialize the [ServerOrchestrator].
  ///
  /// Web: nothing to open — return
  /// `BootstrapResult(hasServer: true, orchestrator: null)`.
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
