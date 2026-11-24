// The library is @experimental for its wire protocol; its API, this type
// included, is documented stable. drift/isolate.dart, the other export,
// needs dart:isolate.
// ignore: experimental_member_use
import 'package:drift/remote.dart' show DriftRemoteException;
import 'package:drift_storage/drift_storage.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:sqlite3/common.dart' show SqliteException;

import 'package:web_storage/src/composition/web_database_exclusivity.dart';
import 'package:web_storage/src/composition/web_database_in_use.dart';
import 'package:web_storage/src/composition/web_database_open_failure.dart';
import 'package:web_storage/src/databases/wasm_executor_factory.dart';
import 'package:web_storage/src/databases/web_storage_persistence.dart';

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
/// The [ServerDatabase], and the `UnsentChangesNoticeRepository` over it
/// (#142). `GameRepository` reads per user, so it is registered in the
/// user-session scope by `UserSessionScopeInstaller`, which web runs too
/// (#434).
///
/// ## No key, no recovery flow
///
/// `StorageScopeInstaller`'s one-shot key-loss recovery (delete key, delete
/// file, reopen, report) has no analogue here, because there is no key:
/// web databases are plaintext by decision (#63, documented at
/// [WebWasmExecutorFactory]). A corrupt web database is not a key mismatch
/// and must not be silently deleted, so nothing is deleted here. A database
/// that won't open throws [WebDatabaseOpenFailure]; deleting it is
/// `deleteServerDatabases`, behind a confirmation the app layer owns (#793).
///
/// ## One tab at a time on `unsafeIndexedDb` (#686)
///
/// On that storage each tab works on its own copy of the database, read once
/// when it opens, and writes its pages back over the other tabs'. Two tabs
/// open at once can lose one tab's writes, and the sync queue can send an op
/// twice or out of order. So when the open lands there, the tab must hold the
/// database (a [WebDatabaseExclusivity], Web Locks in production) before the
/// first query, and holds it until the scope disposes the database.
///
/// A second tab waits up to `exclusiveWait` for the hold, long enough for a
/// reloaded page to outlast the page it replaces. If the other tab still
/// holds it, the second tab closes its connection, having read and written
/// nothing, and [install] throws [WebDatabaseInUse].
///
/// Durable and in-memory storage take no hold, and nor does a browser context
/// without Web Locks: those open as before.
class WebStorageInstaller {
  /// Creates the installer.
  ///
  /// `factory` opens the wasm database; `onReport` is the app layer's
  /// notification hook and may be null. `exclusivity` takes the one-tab hold
  /// on `unsafeIndexedDb`, waiting up to `exclusiveWait` for another tab to
  /// let go (#686).
  const WebStorageInstaller({
    this._factory = const WebWasmExecutorFactory(),
    this._onReport,
    this._exclusivity = const WebLocksDatabaseExclusivity(),
    this._exclusiveWait = defaultExclusiveWait,
  });

  /// How long a tab waits for another to let go of the database before it
  /// reports the database in use (#686). Long enough for a reload, whose old
  /// page may still hold it when the new one asks; short enough that a second
  /// tab hears soon.
  static const Duration defaultExclusiveWait = Duration(seconds: 2);

  final WebWasmExecutorFactory _factory;
  final WebStorageReport? _onReport;
  final WebDatabaseExclusivity _exclusivity;
  final Duration _exclusiveWait;

  /// Opens the database for [identity]'s origin and registers it in
  /// [container], with the `UnsentChangesNoticeRepository` over it (#142).
  ///
  /// The database is keyed by [ServerIdentity.serverId] — the server-vended
  /// UUID, the same value the web scope keys everything else by. Web talks to
  /// one origin, so this is not about switching servers; it is about a
  /// redeployed origin (a genuinely different server behind the same URL) not
  /// silently inheriting the previous one's rows.
  ///
  /// Throws [WebDatabaseInUse] when the database landed on `unsafeIndexedDb`
  /// and another tab holds it (#686).
  Future<void> install(
    DependencyContainer container,
    ServerIdentity identity,
  ) async {
    final opening = await _factory.serverDatabase(identity.serverId);

    // Before the first query, which is where the worker reads the stored
    // file: a tab refused here has read nothing, so it has no stale copy to
    // write back (#686). That rests on drift offering `unsafeIndexedDb` only
    // once its dedicated worker answered the probe (2.35.4): its in-page
    // fallback reads the file during the open, before this hold. From here
    // on, every way out gives the hold back.
    final release = await _hold(
      opening,
      WebWasmExecutorFactory.databaseName(identity.serverId),
    );

    // WAL off (#288): sqlite3-wasm does not support it. Measured as a
    // silent no-op rather than a throw, so this is explicitness, not a
    // crash fix — see `BgeMigrationDefaults.applyStandardPragmas`.
    final ServerDatabase db;
    try {
      db = ServerDatabase(opening.executor, enableWriteAheadLog: false);
    } catch (_) {
      // Nothing was queried, so the connection closes like a refused one.
      await _closeUnused(opening);
      release();
      rethrow;
    }

    // Force the open (and therefore `onCreate`/migrations) here, for the
    // same reason the native installer does: drift would otherwise defer it
    // to an arbitrary first repository call, moving any failure out of
    // bootstrap and into a feature screen.
    try {
      await db.customSelect('SELECT 1').get();
    } catch (error, stackTrace) {
      await _safeClose(db);
      // Kept, the hold would lock this tab out of its own retry.
      release();
      // Typed so the app layer can tell a database that won't open, which
      // deleting it can fix, from any other failure (#793).
      if (_isStoredDataFault(error)) {
        Error.throwWithStackTrace(WebDatabaseOpenFailure(error), stackTrace);
      }
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
      container
        ..registerSingleton<ServerDatabase>(
          db,
          // Released once the database is closed, so the next tab can't open
          // it while this one may still write. Closing only hangs up on the
          // worker, which goes on to run what it was already sent, so a held
          // database first settles those statements.
          dispose: (database) async {
            try {
              if (!identical(release, _releaseNothing)) {
                await _settle(database);
              }
              await database.close();
            } finally {
              release();
            }
          },
        )
        // Beside the database it reads, and inside this guard for the same
        // reason: a throw here must still close the database. It holds nothing
        // but the database, so it needs no dispose hook of its own (#142).
        ..registerSingleton<UnsentChangesNoticeRepository>(
          UnsentChangesNoticeRepositoryImpl(db),
        );
    } catch (_) {
      await _safeClose(db);
      release();
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

  /// Takes the one-tab hold on [databaseName] when [opening] landed on
  /// storage that needs it (#686), and answers what gives it back: nothing,
  /// where no hold was taken.
  ///
  /// Throws [WebDatabaseInUse] when another tab holds it, after closing the
  /// connection, which nothing has queried yet.
  Future<void Function()> _hold(
    WebDatabaseOpening opening,
    String databaseName,
  ) async {
    if (opening.persistence != WebStoragePersistence.unsafe) {
      return _releaseNothing;
    }
    switch (await _exclusivity.acquire(databaseName, wait: _exclusiveWait)) {
      case WebDatabaseHeld(:final release):
        return release;
      case WebDatabaseHoldUnavailable():
        return _releaseNothing;
      case WebDatabaseHeldElsewhere():
        await _closeUnused(opening);
        throw WebDatabaseInUse(databaseName);
    }
  }

  static void _releaseNothing() {}

  /// How long a dispose waits for the statements already sent to settle
  /// before it closes the database anyway.
  static const Duration _settleLimit = Duration(seconds: 5);

  /// Waits until the worker has run, and flushed to storage, every statement
  /// [database] already sent it (#686).
  ///
  /// The worker runs statements one at a time, in the order they arrive, and
  /// flushes each write before the next starts, so a query sent last finishes
  /// last. Best-effort: a query that fails or outlasts [_settleLimit] still
  /// lets the dispose close the database and give the hold back.
  static Future<void> _settle(ServerDatabase database) async {
    try {
      await database.customSelect('SELECT 1').get().timeout(_settleLimit);
    } on Object catch (_) {
      // The close below and the release after it matter more.
    }
  }

  /// Closes the connection of an [opening] nothing has queried. Best-effort,
  /// like [_safeClose]: the in-use error is the one that matters.
  static Future<void> _closeUnused(WebDatabaseOpening opening) async {
    try {
      await opening.executor.close();
    } on Object catch (_) {
      // Nothing was read or written through it.
    }
  }

  /// Whether [error], raised by the forced open, is about the stored database
  /// rather than the engine (#793).
  ///
  /// The worker loads `sqlite3.wasm` and opens the storage lazily, on that
  /// first query, so a missing or blocked wasm asset, or storage the browser
  /// won't provide, fails there too, as a [DriftRemoteException]. Deleting
  /// the database can't fix those. A database fault is a [SqliteException]
  /// raised in the worker, which drift's shared worker sends back as its text
  /// (measured on 2.35.4; protocol v4 can send it typed, so both count). An
  /// error raised in this page, such as a `SchemaDowngradeError` from a
  /// migration, or a [SqliteException] from a database hosted in the page, is
  /// about the stored database too.
  static bool _isStoredDataFault(Object error) => switch (error) {
    DriftRemoteException(:final remoteCause) =>
      remoteCause is SqliteException ||
          '$remoteCause'.startsWith('SqliteException('),
    _ => true,
  };

  /// Closes a database whose open may have failed; drift can throw again from
  /// `close()` in that situation, which is irrelevant here.
  Future<void> _safeClose(ServerDatabase db) async {
    try {
      await db.close();
    } on Object catch (_) {
      // Best-effort: the executor never opened successfully.
    }
  }
}
