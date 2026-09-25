import 'package:app_shell/app_shell.dart';
import 'package:di/di.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart';
import 'package:url_strategy/url_strategy.dart';
import 'package:web_network/web_network.dart';

import 'web_root_module.dart';

/// Installs path-based URLs (no `#` fragments) so the reserved deep-link
/// paths (#10) are real browser URLs. Call first in the browser app's
/// `main()`, before `runBgeApp`.
void configureWebUrlStrategy() => setPathUrlStrategy();

/// Web [PlatformBootstrap].
///
/// The browser can only talk to the origin in the address bar: a server is
/// present by construction, there is no MetaDB, no server switching, and no
/// orchestration (confirmed #31 design). Auth is cookie-owned via
/// `web_network`; [initialize] fetches the origin's [ServerIdentity] from
/// its well-known document and assembles the single-origin scope (#96).
///
/// Since #288 the production scope also carries a `ServerDatabase` over
/// `web_storage`'s drift/wasm executor, but that composition is injected
/// rather than built here — see [bgeWebPlatformBootstrap] in
/// `web_storage_composition.dart` and the note on [_serverScopeBuilder].
class WebPlatformBootstrap implements PlatformBootstrap {
  /// Not const since #384: the instance holds the server [initialize] built,
  /// so that [dispose] can release it.
  WebPlatformBootstrap({this._rootModule, this._serverScopeBuilder});

  /// Injectable root-module seam (#69); null → [registerWebRootModule].
  final Future<void> Function(DependencyContainer container)? _rootModule;

  /// Injectable web-server-scope seam (#96); null → the storage-less
  /// [bootstrapWebServerScope].
  ///
  /// Injectable so bootstrap/cubit tests can supply a fake scope without the
  /// live same-origin well-known fetch (`Uri.base` has no origin on the VM).
  ///
  /// **The default is storage-less on purpose** (#288). Composing the
  /// drift/wasm data layer in here would drag `dart:js_interop` into this
  /// library and make this package — and its whole test suite — browser-only.
  /// The composed builder lives in `web_storage_composition.dart`; the
  /// browser app gets it from [bgeWebPlatformBootstrap], and that is the
  /// only production caller.
  final Future<ActiveServerScope> Function()? _serverScopeBuilder;

  /// The server [initialize] built, held so that [dispose] can release it.
  ActiveServer? _server;

  /// Set by the first [dispose] call and returned to every later one.
  Future<void>? _disposal;

  /// Completes when the latest [initialize] attempt ends, however it ends.
  Future<void>? _attemptEnded;

  /// Builds the web root container (#72): a fresh, isolated
  /// [DependencyContainerImpl] populated by the injected root module
  /// (production default: [registerWebRootModule] — [BuildInfo] from
  /// `version.json` plus the in-memory [FeedbackSink] stand-in; #35,
  /// #69).
  ///
  /// Fresh per call, no shared global GetIt state — see the contract on
  /// [PlatformBootstrap.createRootContainer], including the no-throw
  /// requirement the default module honors per-registration.
  ///
  /// **Dispose-partial guard** (deferred from #74's review, landed with
  /// #69): a module that throws mid-population — a contract violation —
  /// would otherwise leak whatever it registered before the throw, since
  /// `runBgeApp` discards the container for its empty fallback. The
  /// partial container is disposed here first, then the violation
  /// propagates unchanged.
  @override
  Future<DependencyContainer> createRootContainer() async {
    final container = DependencyContainerImpl();
    try {
      await (_rootModule ?? registerWebRootModule)(container);
    } on Object {
      try {
        await container.dispose();
      } on Object {
        // Intentionally ignored: a failure while disposing the partial
        // container must not mask the module's original error — that is
        // the one runBgeApp breadcrumbs and the user must see, so only
        // it is rethrown below. (Native additionally logs this secondary
        // failure at warn via its bootstrap logger; web's bootstrap
        // keeps no logger, so it is simply dropped.)
      }
      rethrow;
    }
    return container;
  }

  /// Web has no out-of-band deep-link channel (#10 decision): the browser
  /// can only navigate within its origin, the address-bar URL *is* the
  /// link, and the path URL strategy installed by
  /// [configureWebUrlStrategy] already hands it to `go_router` directly.
  /// The `/server/:serverId/...` segment in web URLs is carried for
  /// scheme parity with native but neither validated nor used for
  /// switching — single-origin means there is only one place to connect.
  @override
  DeepLinkSource? createDeepLinkSource() => null;

  /// Web's process-wide log sink (#100): a [PrintLogSink] → the browser
  /// console. `dart:developer`'s DevTools bridge is unavailable in a
  /// deployed release web build (no attached VM service), so plain `print`
  /// is the dependable path. Level filtering is applied upstream by
  /// `ShellObservability`.
  @override
  LogSink createLogSink() => PrintLogSink();

  /// Fetches the serving origin's identity and assembles the single-origin
  /// server scope (#96), returning it in the [BootstrapResult].
  ///
  /// Web has exactly one server — the origin in the address bar — so there
  /// is no MetaDB to open and no orchestrator to construct: [hasServer] is
  /// always `true` and `orchestrator` is always `null`. The scope comes from
  /// [_serverScopeBuilder] — for the browser app, `buildWebServerScope` from
  /// `web_storage_composition.dart`, which fetches
  /// `/.well-known/bge-identity` from the origin, wires the cookie-based
  /// network stack, and opens the web database. Defaulted here to the
  /// storage-less [bootstrapWebServerScope]; see the field's docs.
  ///
  /// A well-known fetch failure propagates unchanged;
  /// `runBgeApp`/`AppBootstrapCubit` surface it as the shared retryable
  /// bootstrap-failure state. Web never routes to a "needs server" state — a
  /// server exists by construction, and `/server-add` is unreachable.
  ///
  /// Throws [StateError] once [dispose] has been called, the same rule as
  /// native (#384). An attempt that [dispose] lands on disposes the scope it
  /// built instead of committing it.
  @override
  Future<BootstrapResult> initialize() {
    final attempt = _initialize();
    // The error, if any, is the caller's; dispose() only waits for the end.
    // Attempts never overlap (a caller rule on PlatformBootstrap.initialize),
    // so the latest is the only one in flight.
    _attemptEnded = attempt.then<void>((_) {}, onError: (Object _) {});
    return attempt;
  }

  Future<BootstrapResult> _initialize() async {
    _throwIfDisposed();
    // Retry hygiene, as on native: release a server an earlier attempt
    // committed, or it would be dropped still holding its database.
    await _release();
    final scope = await (_serverScopeBuilder ?? bootstrapWebServerScope)();
    if (_disposal != null) {
      // Nothing is left to reach this scope, so it is released here.
      try {
        await scope.active?.container.dispose();
      } on Object {
        // Intentionally ignored, as in createRootContainer: the StateError
        // below is the one the caller has to see.
      }
      throw _disposedError();
    }
    _server = scope.active;
    return BootstrapResult(hasServer: true, activeServerScope: scope);
  }

  /// Disposes the per-server container [initialize] built (#384): the
  /// drift/wasm database and the user session (#288, #137).
  ///
  /// Every caller gets the same future, so a second caller waits for the
  /// teardown the first one started. A failure propagates to the caller;
  /// `runBgeApp`'s teardown breadcrumbs it.
  @override
  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    // An attempt in flight sees _disposal and releases its own scope; wait
    // for that, so that returning here means everything is closed.
    await _attemptEnded;
    await _release();
  }

  /// Disposes the held server's container, if any, without ending this
  /// bootstrap.
  Future<void> _release() async {
    final server = _server;
    _server = null;
    await server?.container.dispose();
  }

  void _throwIfDisposed() {
    if (_disposal != null) throw _disposedError();
  }

  StateError _disposedError() =>
      StateError('WebPlatformBootstrap has been disposed.');

  @override
  bool get supportsReset => false;

  @override
  Future<void> reset() async {
    throw UnsupportedError(
      'reset() is not supported on web: there is no device-local meta '
      'database to delete.',
    );
  }

  @override
  Future<HydratedStorageDirectory> hydratedStorageDirectory() async =>
      HydratedStorageDirectory.web;
}
