// #288's browser acceptance criteria, executed rather than inspected:
//
//   * a repository read/write round-trips through a real drift/wasm database;
//   * the OPFS-unavailable fallback is exercised;
//   * a degraded browser is classified and reported, not swallowed.
//
// Needs `sqlite3.wasm` and `drift_worker.js` beside this file — fetch them
// with `melos run web:assets` (they are gitignored; see #288 D2). Run with
// `melos run test:web`, or `flutter test --platform chrome` in this package.
//
// ## About OPFS in this harness
//
// The `flutter test --platform chrome` server sends no cross-origin isolation
// headers, and Chrome does not let a shared worker spawn a dedicated one — so
// **both** OPFS modes are unavailable here and drift falls back to IndexedDB.
// That makes the fallback the default path under test rather than something
// to simulate, which is why the assertion below is on `missingFeatures` being
// non-empty while persistence stays real.
//
// Nothing covers the OPFS path — not here and not elsewhere — and that is the
// state of the deployment rather than a gap in this file:
//
//   * `opfsShared` needs a shared worker that can spawn a dedicated one,
//     which only Firefox implements today (Chrome: crbug.com/1088481; Safari
//     likewise). Firefox users get OPFS; nobody else does.
//   * `opfsLocks` needs `SharedArrayBuffer`, which needs cross-origin
//     isolation. Nothing in this repo sends `Cross-Origin-Opener-Policy` or
//     `Cross-Origin-Embedder-Policy` — `tool/dev_proxy/dev_proxy.mjs`
//     forwards upstream response headers untouched, and `flutter run
//     -d web-server` sends neither — so this mode is unreachable in
//     production as it stands, not merely in the test harness.
//
// Serving those two headers is what would unlock `opfsLocks`, the better of
// the two storage mechanisms. Until that is decided, IndexedDB is the real
// production path on Chrome and Safari, and it is what this file exercises.
@TestOn('browser')
library;

import 'package:drift/wasm.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:di/di.dart' show DependencyContainerImpl;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:web_storage/web_storage.dart';

/// A distinct database per test, so IndexedDB state cannot leak between them.
var _counter = 0;
String _uniqueServerId() =>
    'srv-${DateTime.now().microsecondsSinceEpoch}-'
    '${_counter++}';

Game _game({String id = 'g-1', String title = 'Web Round Trip'}) {
  final now = DateTime.now().toUtc();
  return Game(
    id: id,
    title: title,
    contentType: ContentType.baseGame,
    totalPlayCount: 0,
    categories: const [],
    mechanics: const [],
    designers: const [],
    publishers: const [],
    tags: const [],
    visibility: Visibility.public,
    createdAt: now,
    updatedAt: now,
  );
}

/// Shaped like `testServerIdentity` in `core/di`'s fixtures; only
/// [ServerIdentity.serverId] matters here — it is what the database name is
/// derived from.
ServerIdentity _identity(String serverId) => ServerIdentity(
  serverId: serverId,
  issuer: 'https://origin.example.com',
  wellKnownSchemaVersion: 1,
  name: 'Test Origin',
  deviceAuthorizationEndpoint: '/api/auth/device',
  authBasePath: '/api/auth',
  sessionEndpoint: '/api/auth/get-session',
  signOutEndpoint: '/api/auth/sign-out',
  passkeySupported: true,
  twoFactorSupported: true,
  anonymousAuthSupported: true,
);

void main() {
  group('WebWasmExecutorFactory', () {
    test(
      'opens a working database, and reports which storage the browser gave '
      'it — IndexedDB here, because OPFS is unavailable in this harness',
      () async {
        final opening = await const WebWasmExecutorFactory().serverDatabase(
          _uniqueServerId(),
        );

        // The fallback actually happened: drift wanted OPFS and could not
        // have it. This is the OPFS-unavailable path, not a simulation of it.
        expect(opening.missingFeatures, isNotEmpty);
        expect(
          opening.implementation.storageApi,
          WebStorageApi.indexedDb,
          reason: 'this harness offers no OPFS; drift should fall back',
        );

        // …and the fallback is still real persistence, not the in-memory
        // last resort.
        expect(opening.persistence, WebStoragePersistence.durable);
        expect(opening.persistence.isPersistent, isTrue);
        expect(opening.describe(), contains(opening.implementation.name));

        final db = ServerDatabase(opening.executor, enableWriteAheadLog: false);
        addTearDown(db.close);
        await db.customSelect('SELECT 1').get();
      },
    );

    test('a repository read/write round-trips', () async {
      final opening = await const WebWasmExecutorFactory().serverDatabase(
        _uniqueServerId(),
      );
      final db = ServerDatabase(opening.executor, enableWriteAheadLog: false);
      addTearDown(db.close);

      final repository = GameRepositoryImpl(db);

      // Write through the shared repository — the one native uses, no web
      // variant — and read it back out of sqlite, not out of a cache.
      await repository.cacheGame(_game(title: 'Brass: Birmingham'));
      final read = await repository.getGame('g-1');

      expect(read, isNotNull);
      expect(read!.title, 'Brass: Birmingham');

      final missing = await repository.getGame('nope');
      expect(missing, isNull);
    });

    test('data survives closing and reopening the same database', () async {
      // The point of persistent storage, asserted rather than assumed: a
      // second open of the same name sees the first open's rows.
      final serverId = _uniqueServerId();
      const factory = WebWasmExecutorFactory();

      final first = await factory.serverDatabase(serverId);
      final firstDb = ServerDatabase(
        first.executor,
        enableWriteAheadLog: false,
      );
      await GameRepositoryImpl(firstDb).cacheGame(_game(title: 'Persisted'));
      await firstDb.close();

      final second = await factory.serverDatabase(serverId);
      final secondDb = ServerDatabase(
        second.executor,
        enableWriteAheadLog: false,
      );
      addTearDown(secondDb.close);

      final read = await GameRepositoryImpl(secondDb).getGame('g-1');
      expect(read?.title, 'Persisted');
    });

    test('WAL is off, and foreign keys are still on', () async {
      // #288 D4 from the web side. `journal_mode = WAL` is a silent no-op on
      // sqlite3-wasm rather than an error, so the only way to know the
      // parameter is doing what it claims is to read the mode back.
      final opening = await const WebWasmExecutorFactory().serverDatabase(
        _uniqueServerId(),
      );
      final db = ServerDatabase(opening.executor, enableWriteAheadLog: false);
      addTearDown(db.close);

      final journal = await db.customSelect('PRAGMA journal_mode;').getSingle();
      expect((journal.data.values.first as String).toLowerCase(), isNot('wal'));

      final fk = await db.customSelect('PRAGMA foreign_keys;').getSingle();
      expect(fk.data.values.first, 1);
    });

    test('database names are storage-safe, and derived from the server id', () {
      // The name becomes an OPFS directory and an IndexedDB database name, so
      // a UUID's hyphens must not survive into it.
      expect(
        WebWasmExecutorFactory.databaseName('8f14e45f-ceea-467a-9d2b-1c0f'),
        'bge_server_8f14e45f_ceea_467a_9d2b_1c0f',
      );
      expect(
        WebWasmExecutorFactory.databaseName('a/b\\c.d'),
        'bge_server_a_b_c_d',
      );
      expect(WebWasmExecutorFactory.databaseName('plain'), 'bge_server_plain');
    });

    test('an empty server id is rejected rather than opening a shared db', () {
      expect(
        () => const WebWasmExecutorFactory().serverDatabase(''),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('WebStoragePersistence', () {
    test('classifies every storage implementation drift can choose', () {
      expect(
        WebStoragePersistence.of(WasmStorageImplementation.opfsShared),
        WebStoragePersistence.durable,
      );
      expect(
        WebStoragePersistence.of(WasmStorageImplementation.opfsLocks),
        WebStoragePersistence.durable,
      );
      expect(
        WebStoragePersistence.of(WasmStorageImplementation.sharedIndexedDb),
        WebStoragePersistence.durable,
      );
      expect(
        WebStoragePersistence.of(WasmStorageImplementation.unsafeIndexedDb),
        WebStoragePersistence.unsafe,
      );
      expect(
        WebStoragePersistence.of(WasmStorageImplementation.inMemory),
        WebStoragePersistence.ephemeral,
      );
    });

    test('only the in-memory fallback is non-persistent', () {
      expect(WebStoragePersistence.durable.isPersistent, isTrue);
      expect(WebStoragePersistence.unsafe.isPersistent, isTrue);
      expect(WebStoragePersistence.ephemeral.isPersistent, isFalse);
    });
  });

  group('WebStorageInstaller', () {
    test('registers an open ServerDatabase into the scope', () async {
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);

      await const WebStorageInstaller().install(
        container,
        _identity(_uniqueServerId()),
      );

      final db = container.get<ServerDatabase>();

      // Open, migrated and queryable *without* a first read forcing it —
      // the eager open the native installer also does.
      expect(db.enableWriteAheadLog, isFalse);
      await GameRepositoryImpl(db).cacheGame(_game(title: 'Installed'));
      expect((await GameRepositoryImpl(db).getGame('g-1'))?.title, 'Installed');
    });

    test('disposing the scope closes the database', () async {
      final container = DependencyContainerImpl();
      await const WebStorageInstaller().install(
        container,
        _identity(_uniqueServerId()),
      );
      final db = container.get<ServerDatabase>();

      await container.dispose();

      await expectLater(db.customSelect('SELECT 1').get(), throwsA(anything));
    });

    test('reports the storage it got', () async {
      WebDatabaseOpening? reported;
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);

      await WebStorageInstaller(onReport: (opening) => reported = opening)
          .install(container, _identity(_uniqueServerId()));

      expect(reported, isNotNull);
      expect(reported!.implementation, isNotNull);
      expect(reported!.persistence, WebStoragePersistence.durable);
    });

    // The degraded implementations cannot be provoked in this browser: they
    // need a browser missing features Chrome has. Substituting drift's open
    // — while keeping a REAL executor underneath, so the database still
    // works — is what makes those branches assertable at all.
    for (final (implementation, expected)
        in <(WasmStorageImplementation, WebStoragePersistence)>[
          (
            WasmStorageImplementation.unsafeIndexedDb,
            WebStoragePersistence.unsafe,
          ),
          (WasmStorageImplementation.inMemory, WebStoragePersistence.ephemeral),
        ]) {
      test('reports ${implementation.name} as ${expected.name}', () async {
        final real = await WasmDatabase.open(
          databaseName: WebWasmExecutorFactory.databaseName(_uniqueServerId()),
          sqlite3Uri: Uri.parse('sqlite3.wasm'),
          driftWorkerUri: Uri.parse('drift_worker.js'),
        );

        WebDatabaseOpening? reported;
        final container = DependencyContainerImpl();
        addTearDown(container.dispose);

        await WebStorageInstaller(
          factory: WebWasmExecutorFactory(
            open:
                ({
                  required String databaseName,
                  required Uri sqlite3Uri,
                  required Uri driftWorkerUri,
                }) async => WasmDatabaseResult(
                  real.resolvedExecutor,
                  implementation,
                  const {MissingBrowserFeature.dedicatedWorkers},
                ),
          ),
          onReport: (opening) => reported = opening,
        ).install(container, _identity(_uniqueServerId()));

        expect(reported!.persistence, expected);
        expect(reported!.describe(), contains(expected.name));
        expect(container.get<ServerDatabase>(), isNotNull);
      });
    }

    test('a throwing report does not take the install down with it', () async {
      // Regression: reporting happens inside `install`, and
      // `bootstrapWebServerScope` disposes the whole container on any throw
      // from the seam — so an exception from a diagnostics hook used to
      // close a database that had opened perfectly well, failing the boot.
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);

      await WebStorageInstaller(
        onReport: (_) => throw StateError('the logger is broken'),
      ).install(container, _identity(_uniqueServerId()));

      final db = container.get<ServerDatabase>();
      expect(await db.customSelect('SELECT 1').get(), isNotEmpty);
    });

    test('a failed open propagates and registers nothing', () async {
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);

      await expectLater(
        WebStorageInstaller(
          factory: WebWasmExecutorFactory(
            open: ({
              required String databaseName,
              required Uri sqlite3Uri,
              required Uri driftWorkerUri,
            }) async => throw StateError('no storage for you'),
          ),
        ).install(container, _identity(_uniqueServerId())),
        throwsStateError,
      );

      expect(
        () => container.get<ServerDatabase>(),
        throwsA(anything),
        reason: 'a half-installed scope must not look installed',
      );
    });

    test('a failed registration closes the database it just opened', () async {
      // Regression: the open is guarded, so the register has to be too.
      // Between the two, the database belongs to nobody — the container
      // cannot dispose what it never received — so a throw from
      // `registerSingleton` used to strand an open wasm database along with
      // its worker and its IndexedDB connection.
      //
      // A disposed container is the cheapest way to make registration throw,
      // and one of the two cases the guard names.
      final real = await WasmDatabase.open(
        databaseName: WebWasmExecutorFactory.databaseName(_uniqueServerId()),
        sqlite3Uri: Uri.parse('sqlite3.wasm'),
        driftWorkerUri: Uri.parse('drift_worker.js'),
      );

      final container = DependencyContainerImpl();
      await container.dispose();

      await expectLater(
        WebStorageInstaller(
          factory: WebWasmExecutorFactory(
            open:
                ({
                  required String databaseName,
                  required Uri sqlite3Uri,
                  required Uri driftWorkerUri,
                }) async => WasmDatabaseResult(
                  real.resolvedExecutor,
                  WasmStorageImplementation.sharedIndexedDb,
                  const {},
                ),
          ),
        ).install(container, _identity(_uniqueServerId())),
        throwsStateError,
      );

      // Closing the `ServerDatabase` closes the executor under it, so a
      // fresh database over the same executor can no longer query.
      await expectLater(
        ServerDatabase(
          real.resolvedExecutor,
          enableWriteAheadLog: false,
        ).customSelect('SELECT 1').get(),
        throwsA(anything),
        reason: 'the stranded database should have been closed',
      );
    });
  });
}
