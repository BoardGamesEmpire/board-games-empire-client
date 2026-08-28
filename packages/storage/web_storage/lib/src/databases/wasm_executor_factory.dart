import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

import 'web_storage_persistence.dart';

/// The outcome of opening a web database: the executor, plus what kind of
/// storage the browser turned out to offer.
///
/// The diagnostics are part of the return value rather than a log line
/// because they are a decision input, not trivia: [persistence] of
/// [WebStoragePersistence.ephemeral] means this "database" forgets
/// everything on reload, and the app layer is entitled to say so.
final class WebDatabaseOpening {
  /// Wraps the results of one open.
  const WebDatabaseOpening({
    required this.executor,
    required this.implementation,
    required this.missingFeatures,
  });

  /// The connection to hand to a `ServerDatabase`.
  final QueryExecutor executor;

  /// The storage mechanism drift selected.
  final WasmStorageImplementation implementation;

  /// Browser features drift probed for and did not find.
  ///
  /// Non-empty is normal, not an error: it is why [implementation] is what
  /// it is. Under `flutter test --platform chrome`, for instance, OPFS is
  /// unavailable because the test server sends no cross-origin isolation
  /// headers and Chrome does not let a shared worker spawn a dedicated one.
  final Set<MissingBrowserFeature> missingFeatures;

  /// How much persistence [implementation] actually provides.
  WebStoragePersistence get persistence =>
      WebStoragePersistence.of(implementation);

  /// A one-line summary for a log sink or a diagnostics screen.
  String describe() =>
      '${implementation.name} (${persistence.name})'
      '${missingFeatures.isEmpty ? '' : ', missing: '
                '${missingFeatures.map((f) => f.name).join(', ')}'}';
}

/// The drift entry point [WebWasmExecutorFactory] calls, as a seam.
///
/// Matches [WasmDatabase.open]'s named parameters so production passes it
/// straight through, and a browser test can substitute a stub.
///
/// The stub is what makes the *degraded* paths testable at all. Which
/// implementation a real open lands on is the browser's decision, not the
/// test's — `unsafeIndexedDb` and `inMemory` in particular need a browser
/// missing features that Chrome under `flutter test` has. Substituting the
/// open lets those branches be asserted deterministically, while a separate
/// test still exercises the real thing end to end.
///
/// Note this is a *browser*-test seam, not a VM one: `package:drift/wasm.dart`
/// reaches `dart:js_interop`, so no VM suite can import this library at all.
typedef DriftWasmOpen = Future<WasmDatabaseResult> Function({
  required String databaseName,
  required Uri sqlite3Uri,
  required Uri driftWorkerUri,
});

/// Opens drift/wasm databases for the browser (#288, #63).
///
/// The web counterpart of `EncryptedExecutorFactory`, and deliberately the
/// same shape: databases obtain their executor from a factory rather than
/// building one inline, so the storage choice, the asset URIs and the
/// diagnostics cannot be wired inconsistently or skipped.
///
/// It supplies a [QueryExecutor] and nothing else. Every database and
/// repository is shared, platform-neutral code in `drift_storage` (#287);
/// there is no web-specific query anywhere.
///
/// ## NO AT-REST ENCRYPTION ON WEB — divergence from #16 (#63)
///
/// Every native database is encrypted with SQLCipher, keyed per server from
/// the platform keychain. **Web databases are plaintext**, and that is a
/// decision, not an omission:
///
///   * the browser **origin sandbox** is the security boundary — OPFS and
///     IndexedDB are already origin-scoped, so another origin cannot read
///     this data;
///   * any key the page can read, **page-injected JavaScript can read too**,
///     so a key shipped to the browser protects against nothing that the
///     sandbox does not already cover;
///   * drift does publish an encrypted wasm build (`sqlite3mc.wasm`), so
///     this is a choice between available options —
///     `tool/fetch_web_assets.dart` fetches the plain `sqlite3.wasm` on
///     purpose.
///
/// Revisit only if the threat model changes: a shared-device deployment
/// where the browser profile itself is not trusted. Until then, do not
/// "fix" this by adding a key.
///
/// ## Storage implementation
///
/// [WasmDatabase.open] probes the browser and picks the most reliable
/// mechanism available — OPFS, then IndexedDB, then in-memory — and also
/// migrates an existing IndexedDB database to OPFS if the browser has since
/// gained support. That last part is why this calls `open` rather than
/// driving `probe` + `WasmProbeResult.open` by hand for finer control: a
/// user whose browser improves should keep their data.
///
/// What it does *not* do is decide whether the answer is good enough. That
/// is [WebDatabaseOpening.persistence], and the caller's call.
class WebWasmExecutorFactory {
  /// Creates the factory.
  ///
  /// [sqlite3Uri] and [driftWorkerUri] locate the two assets fetched by
  /// `melos run web:assets`. They default to bare filenames, resolved by the
  /// browser against the document — correct both for the app (assets sit in
  /// `apps/browser/web/`, served at the root) and for a browser test (assets
  /// sit beside the test in `test/`, which the test server serves at the
  /// root). Override them for a deployment that serves the app from a
  /// sub-path.
  ///
  /// [open] is the drift entry point, injectable so a test can drive the
  /// factory's own logic without a browser.
  const WebWasmExecutorFactory({
    this._sqlite3Uri,
    this._driftWorkerUri,
    this._open,
  });

  static final _defaultSqlite3Uri = Uri.parse('sqlite3.wasm');
  static final _defaultDriftWorkerUri = Uri.parse('drift_worker.js');

  /// Prefix for every database name this factory produces.
  static const _databaseNamePrefix = 'bge_server';

  final Uri? _sqlite3Uri;
  final Uri? _driftWorkerUri;
  final DriftWasmOpen? _open;

  /// Opens the per-server database for [serverId].
  ///
  /// Unlike the native factory this is `async` and returns an already-open
  /// connection rather than a `LazyDatabase`: the storage probe is itself
  /// asynchronous, and deferring it would move a browser-capability failure
  /// to an arbitrary first query. Same reasoning as the native installer's
  /// eager open, one layer down.
  Future<WebDatabaseOpening> serverDatabase(String serverId) async {
    if (serverId.isEmpty) {
      throw ArgumentError.value(serverId, 'serverId', 'must not be empty');
    }

    final result = await (_open ?? _openWithDrift)(
      databaseName: databaseName(serverId),
      sqlite3Uri: _sqlite3Uri ?? _defaultSqlite3Uri,
      driftWorkerUri: _driftWorkerUri ?? _defaultDriftWorkerUri,
    );

    return WebDatabaseOpening(
      executor: result.resolvedExecutor,
      implementation: result.chosenImplementation,
      missingFeatures: result.missingFeatures,
    );
  }

  /// The storage name for [serverId]'s database.
  ///
  /// Drift asks for "valid identifiers" here because the name becomes an
  /// OPFS directory and an IndexedDB database name, so anything outside
  /// `[A-Za-z0-9_]` is folded to `_` — `ServerIdentity.serverId` is a UUID,
  /// whose hyphens would otherwise land in a filesystem path.
  ///
  /// Visible (and stable) because it is effectively a storage location: a
  /// change here orphans every existing user's database.
  static String databaseName(String serverId) {
    final sanitized = serverId.replaceAll(RegExp('[^A-Za-z0-9_]'), '_');
    return '${_databaseNamePrefix}_$sanitized';
  }

  static Future<WasmDatabaseResult> _openWithDrift({
    required String databaseName,
    required Uri sqlite3Uri,
    required Uri driftWorkerUri,
  }) {
    return WasmDatabase.open(
      databaseName: databaseName,
      sqlite3Uri: sqlite3Uri,
      driftWorkerUri: driftWorkerUri,
    );
  }
}
