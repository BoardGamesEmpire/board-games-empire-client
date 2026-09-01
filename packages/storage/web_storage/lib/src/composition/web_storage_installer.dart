import 'package:drift_storage/drift_storage.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import '../databases/wasm_executor_factory.dart';

/// Reports how much persistence the browser gave this session (#288).
///
/// Mirrors `StorageScopeInstaller`'s `onRecovery` hook: the installer states
/// a fact about storage and the app layer decides what the user should be
/// told, so this package never reaches for a UI or a logger.
typedef WebStorageReport = void Function(WebDatabaseOpening opening);

/// Opens the web [ServerDatabase] and registers it into the server scope
/// (#288, #63).
///
/// The web counterpart of `StorageScopeInstaller`, and the same shape where
/// the shapes can be the same:
///
///   * the database is opened **inside** [install], not on first query, so a
///     browser that cannot provide storage fails while the bootstrap is
///     still the thing on screen;
///   * the database is registered as a singleton with a dispose hook, so the
///     scope owns its lifetime.
///
/// ## Why this is not a `ServerScopeInstaller`
///
/// Native's installers implement that interface because they are run by
/// `ServerContextImpl` over a `ServerConfig`. Web has neither: there is one
/// origin, fetched at bootstrap, and no persisted config to install against
/// (#96). Implementing the interface would mean accepting a `ServerConfig`
/// parameter that does not exist on this platform and could only be faked.
/// So this takes the [ServerIdentity] web actually has, and
/// `bootstrapWebServerScope` calls it through its storage seam.
///
/// A general web installer *tier* — the thing that would make this an
/// installer in the native sense — is #289's per-user scope primitive, and
/// is deliberately not built here.
///
/// ## Registrations
///
/// The [ServerDatabase], and the per-server repositories that hold nothing
/// but it — today [GameRepository] (#251).
///
/// Web needs its own registration of that repository rather than
/// inheriting native's: `StorageScopeInstaller` is a `ServerScopeInstaller`
/// run by `ServerContextImpl`, and web runs no such tier (see below). The
/// repository itself is shared — `GameRepositoryImpl` comes from
/// `drift_storage`'s platform-neutral half — so this is one more
/// registration, not a parallel implementation.
///
/// No `dispose:` hook here either, and for the same reason as native: the
/// repository holds only the database, whose own hook closes it, and
/// closing a drift database closes every stream vended from it.
///
/// ## No key, no recovery flow
///
/// `StorageScopeInstaller`'s one-shot key-loss recovery (delete key, delete
/// file, reopen, report) has no analogue here, because there is no key:
/// web databases are plaintext by decision (#63, documented at
/// [WebWasmExecutorFactory]). A corrupt web database is not a key mismatch
/// and must not be silently deleted, so nothing is deleted here.
class WebStorageInstaller {
  /// Creates the installer.
  ///
  /// [factory] opens the wasm database; [onReport] is the app layer's
  /// notification hook and may be null.
  const WebStorageInstaller({
    this._factory = const WebWasmExecutorFactory(),
    this._onReport,
  });

  final WebWasmExecutorFactory _factory;
  final WebStorageReport? _onReport;

  /// Opens the database for [identity]'s origin and registers it in
  /// [container].
  ///
  /// The database is keyed by [ServerIdentity.serverId] — the server-vended
  /// UUID, the same value the web scope keys everything else by. Web talks to
  /// one origin, so this is not about switching servers; it is about a
  /// redeployed origin (a genuinely different server behind the same URL) not
  /// silently inheriting the previous one's rows.
  Future<void> install(
    DependencyContainer container,
    ServerIdentity identity,
  ) async {
    final opening = await _factory.serverDatabase(identity.serverId);

    // WAL off (#288): sqlite3-wasm does not support it. Measured as a
    // silent no-op rather than a throw, so this is explicitness, not a
    // crash fix — see `BgeMigrationDefaults.applyStandardPragmas`.
    final db = ServerDatabase(opening.executor, enableWriteAheadLog: false);

    // Force the open (and therefore `onCreate`/migrations) here, for the
    // same reason the native installer does: drift would otherwise defer it
    // to an arbitrary first repository call, moving any failure out of
    // bootstrap and into a feature screen.
    try {
      await db.customSelect('SELECT 1').get();
    } catch (_) {
      await _safeClose(db);
      rethrow;
    }

    // Registration is where ownership transfers, and it is guarded for the
    // same reason the open above is: between a successful open and a
    // successful register, nothing owns the database. A throw here — a
    // `ServerDatabase` already registered, a container already disposed —
    // would strand an open wasm database, holding its worker and its
    // IndexedDB connection, somewhere the caller cannot reach it: the
    // compensating `container.dispose()` in `bootstrapWebServerScope` fires
    // the dispose hooks the container *has*, and this one never landed.
    try {
      container.registerSingleton<ServerDatabase>(
        db,
        dispose: (database) => database.close(),
      );
      // Inside the same guard as the database: a throw between the two
      // would strand the open wasm database exactly as described above.
      // No dispose hook (#251) — see the class doc.
      container.registerSingleton<GameRepository>(GameRepositoryImpl(db));
    } catch (_) {
      await _safeClose(db);
      rethrow;
    }

    // Reported after registration, and never allowed to fail the install.
    // A degraded-storage notice is not a failure — and the caller treats a
    // throw from here as one: `bootstrapWebServerScope` disposes the
    // container on any throw, which would close the database that had just
    // opened perfectly well. So a broken diagnostics hook is dropped, the
    // way web's bootstrap drops its secondary dispose failures (this
    // package has no logger of its own to report it to).
    try {
      _onReport?.call(opening);
    } on Object {
      // Intentionally ignored; see above.
    }
  }

  /// Closes a database whose open may have failed; drift can throw again from
  /// `close()` in that situation, which is irrelevant here.
  Future<void> _safeClose(ServerDatabase db) async {
    try {
      await db.close();
    } catch (_) {
      // Best-effort: the executor never opened successfully.
    }
  }
}
