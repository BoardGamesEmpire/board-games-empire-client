import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/sync.dart' show CrossTabLock;
import 'package:models/domain.dart' show ServerIdentity;
import 'package:network_interface/network_interface.dart' show WellKnownClient;
import 'package:observability/observability.dart' show BgeLogger, FeedbackSink;
import 'package:web/web.dart' as web;
import 'package:web_network/web_network.dart';
import 'package:web_storage/web_storage.dart';

import 'device_info/web_device_info_reader.dart';
import 'feedback/indexed_db_feedback_sink.dart';
import 'session/web_provider_sign_in_bindings.dart';
import 'session/web_session_bindings.dart';
import 'sync/web_cross_tab_lock.dart';
import 'web_platform_bootstrap.dart';
import 'web_root_module.dart';
import 'web_user_scope_installers.dart';

/// The production web server scope: the cookie-based network stack, the
/// drift/wasm data layer (#288) with the sync drain's cross-tab lock (#447),
/// the per-user session tier (#137), and the cross-tab session monitor
/// (#432).
///
/// This is the composition `bootstrapWebServerScope` deliberately cannot do
/// for itself. `web_network` owns the scope's assembly but must not depend on
/// `web_storage`, whose libraries reach `dart:js_interop` through
/// `package:drift/wasm.dart`; a dependency edge there would drag a
/// browser-only library into a package every native target also builds. This
/// package already depends on both, so the edge lives here — the same
/// arrangement, and the same reason, as `web_platform` owning the root
/// module.
///
/// Passed to [WebPlatformBootstrap] by [bgeWebPlatformBootstrap]; it is not
/// that class's default, because `WebPlatformBootstrap` lives on the neutral
/// side of the split and must stay VM-compilable.
///
/// [providerSignIn] is this page load's capture ([captureWebProviderSignIn]),
/// taken once by [bgeWebPlatformBootstrap] and handed to every scope it
/// builds. Without it the scope offers no provider sign-in (#583).
///
/// [wellKnownClient] and [originProvider] replace the same-origin well-known
/// fetch and the page's origin. They are production API whose only caller is
/// a test, kept because they are the only way to drive this real composition
/// without that fetch; `bootstrapWebServerScope` has had the same two seams
/// since #96. Production passes neither, and `null` means the real client
/// and `WebDioFactory.currentOrigin`.
Future<ActiveServerScope> buildWebServerScope({
  WebProviderSignInBindings? providerSignIn,
  WellKnownClient? wellKnownClient,
  String Function()? originProvider,
}) {
  return bootstrapWebServerScope(
    installStorage: installWebStorage,
    // #137: the per-user tier, over the database registered above.
    // The list itself is VM-compilable and lives in `web.dart`, so what web
    // installs per user is assertable without a browser.
    userInstallers: buildWebUserScopeInstallers(),
    // #432: keeps this tab's session in step with the other tabs', and gates
    // the work that sends as the session on whose it is.
    sessionBindings: webSessionBindings,
    // #583: leaving the page for a sign-in provider, and what this page load
    // brought back from one.
    providerSignIn: providerSignIn,
    wellKnownClient: wellKnownClient,
    originProvider: originProvider ?? WebDioFactory.currentOrigin,
  );
}

/// Installs the server scope's web storage into [container]: the
/// [WebStorageInstaller]'s database and what it carries, then the
/// [CrossTabLock] the user tier's drain runs each pass under (#447).
///
/// Named, not inline in [buildWebServerScope], so that a test can run it over
/// a real container and see that the lock is registered along with the
/// database.
Future<void> installWebStorage(
  DependencyContainer container,
  ServerIdentity identity,
) async {
  await WebStorageInstaller(onReport: reportWebStorage)
      .install(container, identity);
  registerWebCrossTabLock(container);
}

/// Registers the browser's Web Lock in [container] as the [CrossTabLock] the
/// sync drain runs each pass under, so that one tab at a time drains each
/// server database and user (#447).
///
/// `navigator.locks` exists only in a secure context, so a browser context
/// without it, a self-hosted server served over plain http among them,
/// registers nothing, and the drain runs unlocked. Warned, not fatal: two
/// tabs that drain at once can deliver an op twice, which every op type is
/// safe for, and that is better than a queue nothing sends.
/// [locksAvailable] replaces the check for Web Locks, for tests.
void registerWebCrossTabLock(
  DependencyContainer container, {
  bool Function()? locksAvailable,
}) {
  if (!(locksAvailable?.call() ?? web.window.navigator.has('locks'))) {
    _logger.warn(
      'no Web Locks in this browser context; the sync drain runs without a '
      'cross-tab lock',
    );
    return;
  }
  container.registerSingleton<CrossTabLock>(const WebCrossTabLock());
}

/// The browser app's [PlatformBootstrap]: [WebPlatformBootstrap] with the
/// drift/wasm data layer and the durable feedback queue composed in.
///
/// This exists so the app's `main()` cannot get the wiring subtly wrong.
/// `WebPlatformBootstrap()` is a *valid* object that boots a
/// storage-less app, so the mistake it replaces would not fail — it would
/// just quietly have no database. One symbol, named for what it is, is the
/// cheapest guard available.
///
/// Building it reads what this page load brought back from a sign-in
/// provider (#583), and consumes it: call it once, in `main()`, where it runs
/// before `runBgeApp` builds the router that could rewrite the address.
///
/// [wellKnownClient] and [originProvider] are handed to every scope this
/// builds; see [buildWebServerScope]. They are production API whose only
/// caller is a test, kept because they are the only way to drive the real
/// composition without the same-origin well-known fetch, and
/// `bootstrapWebServerScope` has had the same two seams since #96. Production
/// passes neither.
WebPlatformBootstrap bgeWebPlatformBootstrap({
  WellKnownClient? wellKnownClient,
  String Function()? originProvider,
}) {
  final providerSignIn = captureWebProviderSignIn();
  return WebPlatformBootstrap(
    rootModule: buildWebRootModule,
    // A closure rather than the tear-off, so that every attempt, a retry's
    // included, builds its scope over this page load's one capture.
    serverScopeBuilder: () => buildWebServerScope(
      providerSignIn: providerSignIn,
      wellKnownClient: wellKnownClient,
      originProvider: originProvider,
    ),
  );
}

/// The production web **root** module: [registerWebRootModule] with the
/// durable feedback sink (#292) and the browser's device reader (#324)
/// composed in.
///
/// Here for the same reason [buildWebServerScope] is: `web_root_module.dart`
/// is on the VM-compilable side of this package and cannot name a type that
/// reaches `dart:js_interop`, nor `dart:ui_web`'s browser detection, which
/// only exists on the web. This file already cannot run on the VM, so the
/// edge costs nothing that was not already paid.
Future<void> buildWebRootModule(DependencyContainer container) async {
  // Started, not awaited: the module overlaps this with its own platform read
  // rather than queueing behind it. Both carry their own timeout, so the boot
  // waits the longer of the two and not their sum.
  final opening = _openFeedbackSink();
  try {
    await registerWebRootModule(
      container,
      feedbackSink: opening,
      deviceInfoReader: _browserDeviceInfoReader(),
    );
  } on Object {
    // Ownership transfers at registration, and this throw means it never
    // happened: `createRootContainer`'s dispose-partial guard fires the hooks
    // the container *has*, and this one never landed. An unreferenced open
    // connection would then sit there for the life of the page, holding the
    // lock that blocks the next tab's version upgrade — the failure
    // `defaultOpenTimeout` exists to bound. `BuildInfoReader` is contracted
    // not to throw, so this guards a contract rather than a known path; the
    // same reasoning, and the same shape, as `WebStorageInstaller`'s.
    if (await opening case final Disposable disposable) {
      try {
        await disposable.onDispose();
      } on Object {
        // Best-effort: the module's failure is the informative one.
      }
    }
    rethrow;
  }
}

/// Opens the durable feedback queue, or null when the browser will not have
/// one (#292).
///
/// Null rather than a throw, because the root-module contract is that a
/// recoverable platform failure registers a degraded value: a browser that
/// refuses storage — a private window, blocked site data — must still boot,
/// and must still be able to take a crash report, which is the one thing the
/// user has left when everything else has failed.
///
/// Reported at `error` on the same reasoning as an `ephemeral` database: the
/// app keeps working, but a queued report now evaporates on reload, and that
/// is invisible from the outside. The user is told at approval time: the
/// in-memory fallback does not survive a restart, so the outcome screens say
/// the report is held only until the app closes (#385).
Future<FeedbackSink?> _openFeedbackSink() async {
  try {
    return await IndexedDbFeedbackSink.open();
  } on Object catch (error, stackTrace) {
    _logger.error(
      'feedback queue storage is unavailable — approved reports will not '
      'survive a reload this session',
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

/// A [WebDeviceInfoReader] over the engine's own browser detection (#324).
/// Each source is read when the reader is, not here.
WebDeviceInfoReader _browserDeviceInfoReader() => WebDeviceInfoReader(
  userAgent: () => ui_web.browser.userAgent,
  vendor: () => web.window.navigator.vendor,
  browserEngine: () => ui_web.browser.browserEngine.name,
  operatingSystem: () => ui_web.browser.operatingSystem.name,
);

/// Logger for the storage report; named for the layer, matching
/// `bge.platform.native_bootstrap`.
final _logger = BgeLogger('bge.platform.web_storage');

/// Logs what the browser actually gave us for storage.
///
/// Reported rather than swallowed because the answer is not always the good
/// one, and the degraded cases are invisible otherwise — a database that
/// forgets everything on reload behaves like a very fast, very forgetful one.
/// Levels follow the guarantee, not the mechanism:
///
///   * [WebStoragePersistence.durable] → `info`. Which of the durable
///     mechanisms was chosen is still worth recording: it is the first thing
///     to want when a report says "my data vanished".
///   * [WebStoragePersistence.unsafe] → `warn`. Data persists, but a second
///     tab can race it. The sync drain runs there too, under its cross-tab
///     lock, but another tab's inline send takes no lock and can race it
///     for an op (#447).
///   * [WebStoragePersistence.ephemeral] → `error`. Nothing is stored at all.
///     Not thrown, deliberately: a browser this limited can still run the
///     app against the server (web's server is the serving origin and is
///     reachable by construction), and refusing to boot would be a worse
///     outcome than running without a cache.
void reportWebStorage(WebDatabaseOpening opening) {
  final message = 'web database storage: ${opening.describe()}';
  final context = <String, dynamic>{
    'implementation': opening.implementation.name,
    'persistence': opening.persistence.name,
    'missingFeatures': opening.missingFeatures.map((f) => f.name).toList(),
  };

  switch (opening.persistence) {
    case WebStoragePersistence.durable:
      _logger.info(message, context: context);
    case WebStoragePersistence.unsafe:
      _logger.warn(
        '$message — a second tab can race writes to this database; the '
        "sync drain runs there, and another tab's send can deliver an op "
        'twice',
        context: context,
      );
    case WebStoragePersistence.ephemeral:
      _logger.error(
        '$message — nothing is being persisted; this session starts empty '
        'on every reload',
        context: context,
      );
  }
}
