import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart' show BgeLogger, FeedbackSink;
import 'package:web_network/web_network.dart';
import 'package:web_storage/web_storage.dart';

import 'feedback/indexed_db_feedback_sink.dart';
import 'web_platform_bootstrap.dart';
import 'web_root_module.dart';
import 'web_user_scope_installers.dart';

/// The production web server scope: the cookie-based network stack, the
/// drift/wasm data layer (#288), and the per-user session tier (#137).
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
Future<ActiveServerScope> buildWebServerScope() {
  return bootstrapWebServerScope(
    installStorage: WebStorageInstaller(onReport: reportWebStorage).install,
    // #137: the per-user tier, over the database the line above registers.
    // The list itself is VM-compilable and lives in `web.dart`, so what web
    // installs per user is assertable without a browser.
    userInstallers: buildWebUserScopeInstallers(),
  );
}

/// The browser app's [PlatformBootstrap]: [WebPlatformBootstrap] with the
/// drift/wasm data layer and the durable feedback queue composed in.
///
/// This exists so the app's `main()` cannot get the wiring subtly wrong.
/// `WebPlatformBootstrap()` is a *valid* object that boots a
/// storage-less app, so the mistake it replaces would not fail — it would
/// just quietly have no database. One symbol, named for what it is, is the
/// cheapest guard available.
WebPlatformBootstrap bgeWebPlatformBootstrap() => WebPlatformBootstrap(
  rootModule: buildWebRootModule,
  serverScopeBuilder: buildWebServerScope,
);

/// The production web **root** module: [registerWebRootModule] with the
/// durable feedback sink composed in (#292).
///
/// Here for the same reason [buildWebServerScope] is: `web_root_module.dart`
/// is on the VM-compilable side of this package and cannot name a type that
/// reaches `dart:js_interop`. This file already cannot run on the VM, so the
/// edge costs nothing that was not already paid.
Future<void> buildWebRootModule(DependencyContainer container) async {
  // Started, not awaited: the module overlaps this with its own platform read
  // rather than queueing behind it. Both carry their own timeout, so the boot
  // waits the longer of the two and not their sum.
  final opening = _openFeedbackSink();
  try {
    await registerWebRootModule(container, feedbackSink: opening);
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
/// is invisible from the outside. What the user is *told* at approval time is
/// #385 — the prompt promises a later send on every platform today.
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
///     tab can race it.
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
        '$message — a second tab can race writes to this database',
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
