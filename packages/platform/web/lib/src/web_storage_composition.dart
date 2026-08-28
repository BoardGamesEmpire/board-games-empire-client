import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart' show BgeLogger;
import 'package:web_network/web_network.dart';
import 'package:web_storage/web_storage.dart';

import 'web_platform_bootstrap.dart';

/// The production web server scope: the cookie-based network stack **and**
/// the drift/wasm data layer (#288).
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
  );
}

/// The browser app's [PlatformBootstrap]: [WebPlatformBootstrap] with the
/// drift/wasm data layer composed in.
///
/// This exists so the app's `main()` cannot get the wiring subtly wrong.
/// `const WebPlatformBootstrap()` is a *valid* object that boots a
/// storage-less app, so the mistake it replaces would not fail — it would
/// just quietly have no database. One symbol, named for what it is, is the
/// cheapest guard available.
WebPlatformBootstrap bgeWebPlatformBootstrap() =>
    WebPlatformBootstrap(serverScopeBuilder: buildWebServerScope);

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
