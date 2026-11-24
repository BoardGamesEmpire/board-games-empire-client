// #288's browser acceptance criteria, executed rather than inspected:
//
//   * a repository read/write round-trips through a real drift/wasm database;
//   * the OPFS-unavailable fallback is exercised;
//   * a degraded browser is classified and reported, not swallowed.
//
// Needs `sqlite3.wasm` and `drift_worker.js` beside this file — fetch them
// with `melos run web:assets` (they are gitignored; see #288). Run with
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

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:bge_test_support/domain.dart';
import 'package:di/di.dart' show DependencyContainerImpl, LocalClockService;
import 'package:drift/drift.dart'
    show
        ApplyInterceptorConnection,
        BatchedStatements,
        QueryExecutor,
        QueryExecutorUser,
        QueryInterceptor,
        Variable,
        driftRuntimeOptions;
// The library is @experimental for its wire protocol; its API, this type
// included, is documented stable. drift/isolate.dart, the other export,
// needs dart:isolate.
// ignore: experimental_member_use
import 'package:drift/remote.dart' show DriftRemoteException;
import 'package:drift/wasm.dart';
import 'package:drift_storage/drift_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:web/web.dart' as web;
import 'package:web_storage/web_storage.dart';

/// A distinct database per test, so IndexedDB state cannot leak between them.
var _counter = 0;
String _uniqueServerId() =>
    'srv-${DateTime.now().microsecondsSinceEpoch}-'
    '${_counter++}';

const _kUserId = 'user-1';

Game _game({String id = 'g-1', String title = 'Web Round Trip'}) {
  final now = DateTime.now().toUtc();
  return Game(
    id: id,
    title: title,
    createdAt: now,
    updatedAt: now,
  );
}

/// The shared identity under [serverId]: it is what the database name is
/// derived from, and nothing else about the identity matters here.
ServerIdentity _identity(String serverId) =>
    testServerIdentity().copyWith(serverId: serverId);

/// The schema version and change counter as IndexedDB stores them, read from
/// page 1 of the stored file: big-endian `uint32`s at offsets 60 and 24.
///
/// This reads storage, not the worker's memory. The shared worker keeps pages
/// it hasn't flushed, so reopening in the same page would pass with or
/// without a flush. Null for a missing or short file.
Future<({int userVersion, int changeCounter})?> _storedHeader(
  String databaseName,
) async {
  final probe = await WasmDatabase.probe(
    sqlite3Uri: Uri.parse('sqlite3.wasm'),
    driftWorkerUri: Uri.parse('drift_worker.js'),
    databaseName: databaseName,
  );
  final bytes = await probe.exportDatabase((
    WebStorageApi.indexedDb,
    databaseName,
  ));
  if (bytes == null || bytes.length < 64) return null;
  final header = ByteData.sublistView(bytes);
  return (
    userVersion: header.getUint32(60),
    changeCounter: header.getUint32(24),
  );
}

/// The #608 state: a stored file whose schema version reads 0 while its tables
/// exist, so the next open runs `onCreate` over them and fails.
Future<void> _breakStoredDatabase(String serverId) async {
  final opening = await const WebWasmExecutorFactory().serverDatabase(serverId);
  final db = ServerDatabase(opening.executor, enableWriteAheadLog: false);
  await db.customSelect('SELECT 1').get();
  await db.customStatement('PRAGMA user_version = 0');
  await db.close();
}

Future<List<String>> _indexedDbNames() async {
  final infos = (await web.window.indexedDB.databases().toDart).toDart;
  return [for (final info in infos) info.name];
}

/// Opens a raw IndexedDB connection that holds [name] open, as another tab's
/// own copy would. Closed in teardown.
Future<web.IDBDatabase> _holdConnection(String name) async {
  final opened = Completer<web.IDBDatabase>();
  final request = web.window.indexedDB.open(name);
  request.onsuccess = ((web.Event _) {
    opened.complete(request.result! as web.IDBDatabase);
  }).toJS;
  final held = await opened.future;
  // ignore: unnecessary_lambdas, interop members can't be torn off.
  addTearDown(() => held.close());
  return held;
}

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

      final repository = GameRepositoryImpl(db, userId: _kUserId);

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
      await GameRepositoryImpl(
        firstDb,
        userId: _kUserId,
      ).cacheGame(_game(title: 'Persisted'));
      await firstDb.close();

      final second = await factory.serverDatabase(serverId);
      final secondDb = ServerDatabase(
        second.executor,
        enableWriteAheadLog: false,
      );
      addTearDown(secondDb.close);

      final read = await GameRepositoryImpl(
        secondDb,
        userId: _kUserId,
      ).getGame('g-1');
      expect(read?.title, 'Persisted');
    });

    test('WAL is off, and foreign keys are still on', () async {
      // The WAL decision (#288), from the web side. `journal_mode = WAL` is
      // a silent no-op on sqlite3-wasm rather than an error, so the only way
      // to know the parameter is doing what it claims is to read the mode
      // back.
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
        WebWasmExecutorFactory.databaseName(r'a/b\c.d'),
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

  // #608: drift sets `user_version` after `beforeOpen`, and nothing flushes
  // that write to IndexedDB. These read the stored bytes, so a database left
  // without a later write still has to carry its version.
  group('the stored schema version (#608)', () {
    Future<ServerDatabase> open(String serverId) async {
      final opening = await const WebWasmExecutorFactory().serverDatabase(
        serverId,
      );
      final db = ServerDatabase(opening.executor, enableWriteAheadLog: false);
      addTearDown(db.close);
      return db;
    }

    test(
      'a fresh open that writes nothing stores the schema version',
      () async {
        final serverId = _uniqueServerId();
        final db = await open(serverId);
        await db.doWhenOpened((_) {});

        final header = await _storedHeader(
          WebWasmExecutorFactory.databaseName(serverId),
        );
        expect(header?.userVersion, db.schemaVersion);
      },
    );

    test('an upgrade that writes nothing stores the new version', () async {
      final serverId = _uniqueServerId();
      final first = await open(serverId);
      await first.customSelect('SELECT 1').get();
      // Back to v19: undo what the v20 step adds.
      await first.customStatement('DROP TABLE collection_moves');
      await first.customStatement('DROP TABLE collection_refresh_markers');
      await first.customStatement('PRAGMA user_version = 19');
      await first.close();

      final second = await open(serverId);
      await second.doWhenOpened((_) {});

      final header = await _storedHeader(
        WebWasmExecutorFactory.databaseName(serverId),
      );
      expect(header?.userVersion, second.schemaVersion);
      expect(second.schemaVersion, 20);
    });
  });

  // #950: drift 2.34.3 flushed a write to IndexedDB only outside a
  // transaction, so a transaction's writes (its COMMIT included) stayed in the
  // worker's memory until the next plain write. This reads storage.
  group("a transaction's writes reach storage (#950)", () {
    test("a transaction's writes are stored without a later write", () async {
      final serverId = _uniqueServerId();
      final name = WebWasmExecutorFactory.databaseName(serverId);
      final opening = await const WebWasmExecutorFactory().serverDatabase(
        serverId,
      );
      final db = ServerDatabase(opening.executor, enableWriteAheadLog: false);
      addTearDown(db.close);
      await db.customSelect('SELECT 1').get();
      await db.customStatement('CREATE TABLE probe_950 (x INTEGER)');
      final before = (await _storedHeader(name))!.changeCounter;

      await db.transaction(() async {
        await db.customInsert(
          'INSERT INTO probe_950 (x) VALUES (?)',
          variables: [Variable.withInt(1)],
        );
      });

      final after = (await _storedHeader(name))!.changeCounter;
      expect(after, greaterThan(before));
    });
  });

  group('deleteServerDatabases (#793)', () {
    Future<ServerDatabase> open(String serverId) async {
      final opening = await const WebWasmExecutorFactory().serverDatabase(
        serverId,
      );
      return ServerDatabase(opening.executor, enableWriteAheadLog: false);
    }

    test('deletes a closed database, and the next open is fresh', () async {
      final serverId = _uniqueServerId();
      final name = WebWasmExecutorFactory.databaseName(serverId);
      final first = await open(serverId);
      await first.customStatement('CREATE TABLE marker (id INTEGER)');
      await first.close();

      final result = await deleteServerDatabases(namePrefix: name);
      expect(result.deleted, [name]);
      expect(result.blocked, isEmpty);

      final second = await open(serverId);
      addTearDown(second.close);
      final tables = await second
          .customSelect(
            "SELECT name FROM sqlite_master WHERE name = 'marker'",
          )
          .get();
      expect(tables, isEmpty);
    });

    // close() on the page only posts a disconnect; the shared worker closes
    // its IndexedDB connection when it reaches that message. A slow query on
    // another database keeps the worker from reaching it, so the delete
    // arrives while the worker still holds the database. On a slow CI runner
    // that happened without the query, and the delete came back blocked.
    test(
      'a delete straight after a close waits for the worker to let go',
      () async {
        final serverId = _uniqueServerId();
        final name = WebWasmExecutorFactory.databaseName(serverId);
        final busyId = _uniqueServerId();
        final busy = await open(busyId);
        addTearDown(
          () => deleteServerDatabases(
            namePrefix: WebWasmExecutorFactory.databaseName(busyId),
          ),
        );
        addTearDown(busy.close);
        await busy.customSelect('SELECT 1').get();
        final db = await open(serverId);
        await db.customSelect('SELECT 1').get();

        final slow = busy
            .customSelect(
              'WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c '
              'WHERE x < 1000000) SELECT count(*) AS n FROM c',
            )
            .get();
        await db.close();
        final result = await deleteServerDatabases(
          namePrefix: name,
          // Room for the query on a slow runner: the test is about waiting.
          blockedAfter: const Duration(seconds: 20),
        );
        await slow;

        expect(result.deleted, [name]);
        expect(result.blocked, isEmpty);
      },
    );

    // The test above depends on the worker still being busy when the delete
    // arrives. This one doesn't: a holder that stays open through its
    // versionchange makes the browser fire blocked, and letting go after that
    // must still end in a delete.
    test('a delete waits out a block that lifts before the limit', () async {
      final serverId = _uniqueServerId();
      final name = WebWasmExecutorFactory.databaseName(serverId);
      final db = await open(serverId);
      await db.customSelect('SELECT 1').get();
      await db.close();
      final held = await _holdConnection(name);
      final versionChange = Completer<void>();
      held.onversionchange = ((web.Event _) {
        versionChange.complete();
      }).toJS;

      final deleting = deleteServerDatabases(
        namePrefix: name,
        blockedAfter: const Duration(seconds: 5),
      );
      // blocked is queued once versionchange has reached a holder that is
      // still open; staying open a while longer lets it fire first.
      await versionChange.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 200));
      held.close();
      final result = await deleting.timeout(const Duration(seconds: 10));

      expect(result.deleted, [name]);
      expect(result.blocked, isEmpty);
    });

    test('deletes only names with the prefix', () async {
      final firstId = _uniqueServerId();
      final secondId = _uniqueServerId();
      final firstName = WebWasmExecutorFactory.databaseName(firstId);
      final secondName = WebWasmExecutorFactory.databaseName(secondId);
      for (final id in [firstId, secondId]) {
        final db = await open(id);
        await db.customSelect('SELECT 1').get();
        await db.close();
      }
      addTearDown(() => deleteServerDatabases(namePrefix: secondName));

      final result = await deleteServerDatabases(namePrefix: firstName);

      expect(result.deleted, [firstName]);
      final names = await _indexedDbNames();
      expect(names, isNot(contains(firstName)));
      expect(names, contains(secondName));
    });

    test(
      'a delete another connection holds reports it blocked at the limit',
      () async {
        final serverId = _uniqueServerId();
        final name = WebWasmExecutorFactory.databaseName(serverId);
        final db = await open(serverId);
        await db.customSelect('SELECT 1').get();
        await db.close();
        await _holdConnection(name);

        final result = await deleteServerDatabases(
          namePrefix: name,
          blockedAfter: const Duration(milliseconds: 300),
        ).timeout(const Duration(seconds: 5));

        expect(result.blocked, [name]);
        expect(result.deleted, isEmpty);
      },
    );

    test(
      'a second delete behind a blocked one reports it blocked, too',
      () async {
        final serverId = _uniqueServerId();
        final name = WebWasmExecutorFactory.databaseName(serverId);
        final db = await open(serverId);
        await db.customSelect('SELECT 1').get();
        await db.close();
        await _holdConnection(name);

        final first = await deleteServerDatabases(
          namePrefix: name,
          blockedAfter: const Duration(milliseconds: 300),
        );
        expect(first.blocked, [name]);

        // The first request is still queued, so this one fires no event.
        final second = await deleteServerDatabases(
          namePrefix: name,
          blockedAfter: const Duration(milliseconds: 300),
        ).timeout(const Duration(seconds: 5));

        expect(second.blocked, [name]);
        expect(second.deleted, isEmpty);
      },
    );

    test('deletes run together, so the time limit bounds them all', () async {
      final base = _uniqueServerId();
      final prefix = WebWasmExecutorFactory.databaseName(base);
      final names = <String>[];
      for (final id in ['${base}a', '${base}b', '${base}c']) {
        final db = await open(id);
        await db.customSelect('SELECT 1').get();
        await db.close();
        final name = WebWasmExecutorFactory.databaseName(id);
        await _holdConnection(name);
        names.add(name);
      }
      final first = await deleteServerDatabases(
        namePrefix: prefix,
        blockedAfter: const Duration(milliseconds: 300),
      );
      expect(first.blocked, unorderedEquals(names));

      // Each delete now waits behind a blocked one, so each one runs out
      // its time limit. One after another, that would take three limits.
      final watch = Stopwatch()..start();
      final second = await deleteServerDatabases(
        namePrefix: prefix,
        blockedAfter: const Duration(seconds: 1),
      );
      watch.stop();

      expect(second.blocked, unorderedEquals(names));
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 2500)));
    });

    test('without indexedDB.databases(), skips the IndexedDB half', () async {
      // Firefox before 126 has no databases(). Drift's probe skips the
      // listing there, and so does this, rather than throwing a TypeError.
      final serverId = _uniqueServerId();
      final name = WebWasmExecutorFactory.databaseName(serverId);
      final db = await open(serverId);
      await db.customSelect('SELECT 1').get();
      await db.close();
      addTearDown(() => deleteServerDatabases(namePrefix: name));

      final prototype =
          (globalContext['IDBFactory']! as JSObject)['prototype']! as JSObject;
      final databases = prototype['databases'];
      prototype.delete('databases'.toJS);
      addTearDown(() => prototype['databases'] = databases);
      expect(web.window.indexedDB.has('databases'), isFalse);

      final result = await deleteServerDatabases(namePrefix: name);

      expect(result.deleted, isEmpty);
      expect(result.blocked, isEmpty);
    });

    test(
      'the database that fails to open can be deleted, and then opens',
      () async {
        final serverId = _uniqueServerId();
        final name = WebWasmExecutorFactory.databaseName(serverId);
        await _breakStoredDatabase(serverId);

        final container = DependencyContainerImpl();
        addTearDown(container.dispose);
        await expectLater(
          const WebStorageInstaller().install(container, _identity(serverId)),
          throwsA(isA<WebDatabaseOpenFailure>()),
        );

        final result = await deleteServerDatabases(namePrefix: name);
        expect(result.deleted, [name]);

        await const WebStorageInstaller().install(
          container,
          _identity(serverId),
        );
        expect(container.isRegistered<ServerDatabase>(), isTrue);
      },
    );
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
      await GameRepositoryImpl(
        db,
        userId: _kUserId,
      ).cacheGame(_game(title: 'Installed'));
      expect(
        (await GameRepositoryImpl(db, userId: _kUserId).getGame('g-1'))?.title,
        'Installed',
      );
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

    // #434: the game cache reads per user, so web registers it in the
    // user-session scope, through the same `UserSessionScopeInstaller` as
    // native, never here.
    test('does not register GameRepository', () async {
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);

      await const WebStorageInstaller().install(
        container,
        _identity(_uniqueServerId()),
      );

      expect(container.isRegistered<GameRepository>(), isFalse);
    });

    // #142: the sign-in notice counts unsent changes over the same database
    // the sync queue lives in, so web registers the record beside it.
    test(
      'registers the unsent-changes record over the same database (#142)',
      () async {
        final container = DependencyContainerImpl();
        addTearDown(container.dispose);

        await const WebStorageInstaller().install(
          container,
          _identity(_uniqueServerId()),
        );

        final notice = container.get<UnsentChangesNoticeRepository>();
        await notice.recordSessionStarted(_kUserId);
        const clock = LocalClockService();
        await SyncQueueRepositoryImpl(
          container.get<ServerDatabase>(),
          clock,
          userId: _kUserId,
          localNowUtc: clock.nowUtc,
        ).enqueue(
          const AddToCollectionOperation(
            localId: 'local-1',
            platformGameId: 'pg-1',
            medium: 'Physical',
            quantity: 1,
          ),
        );

        expect(await notice.unsentChangesCount(), 1);
      },
    );

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
                  required databaseName,
                  required sqlite3Uri,
                  required driftWorkerUri,
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
              required databaseName,
              required sqlite3Uri,
              required driftWorkerUri,
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

    test('a stored database that fails to open throws '
        'WebDatabaseOpenFailure, and registers nothing', () async {
      final serverId = _uniqueServerId();
      await _breakStoredDatabase(serverId);

      final container = DependencyContainerImpl();
      addTearDown(container.dispose);

      await expectLater(
        const WebStorageInstaller().install(container, _identity(serverId)),
        throwsA(
          isA<WebDatabaseOpenFailure>().having(
            (failure) => failure.cause,
            'cause',
            // The database lives in drift's shared worker, which sends the
            // SqliteException back as its text (measured: a String, not the
            // typed form protocol v4 can carry). The installer reads that
            // text to tell a database fault from a failed engine, so this
            // pins it.
            isA<DriftRemoteException>().having(
              (remote) => '${remote.remoteCause}',
              'remoteCause',
              startsWith('SqliteException('),
            ),
          ),
        ),
      );
      expect(container.isRegistered<ServerDatabase>(), isFalse);
    });

    test('an engine that fails to load at the forced open is not a '
        'WebDatabaseOpenFailure', () async {
      // The worker loads sqlite3.wasm lazily, at the first query, so a
      // missing or blocked asset fails the forced open too. Deleting the
      // database can't fix that, so it must not count toward the reset.
      var opened = false;
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);

      await expectLater(
        WebStorageInstaller(
          factory: WebWasmExecutorFactory(
            open:
                ({
                  required databaseName,
                  required sqlite3Uri,
                  required driftWorkerUri,
                }) async {
                  final result = await WasmDatabase.open(
                    databaseName: databaseName,
                    sqlite3Uri: Uri.parse('missing-sqlite3.wasm'),
                    driftWorkerUri: driftWorkerUri,
                  );
                  opened = true;
                  return result;
                },
          ),
        ).install(container, _identity(_uniqueServerId())),
        throwsA(
          allOf(
            isA<DriftRemoteException>().having(
              (remote) => '${remote.remoteCause}',
              'remoteCause',
              isNot(startsWith('SqliteException(')),
            ),
            isNot(isA<WebDatabaseOpenFailure>()),
          ),
        ),
      );
      expect(opened, isTrue, reason: 'the failure must come from the open');
      expect(container.isRegistered<ServerDatabase>(), isFalse);
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
                  required databaseName,
                  required sqlite3Uri,
                  required driftWorkerUri,
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
      // fresh database over the same executor can no longer query. The probe
      // is closed too: drift counts the databases left open, and one left
      // open makes every later open in the run warn of a second instance.
      final probe = ServerDatabase(
        real.resolvedExecutor,
        enableWriteAheadLog: false,
      );
      addTearDown(probe.close);
      await expectLater(
        probe.customSelect('SELECT 1').get(),
        throwsA(anything),
        reason: 'the stranded database should have been closed',
      );
    });
  });

  // ── #686: on unsafeIndexedDb, each tab works on its own copy ────────────
  //
  // Each tab reads the stored file once, when it opens, and writes its pages
  // back over the other tabs'. So the tab that opens holds a Web Lock named for
  // the database until it disposes it, and a second tab opens nothing. The
  // installer tests fake only the storage mode the open reports, over a real
  // executor, as `reports unsafeIndexedDb as unsafe` does above.
  group('one tab at a time on unsafeIndexedDb (#686)', () {
    group('WebLocksDatabaseExclusivity', () {
      test(
        'held elsewhere when another holder keeps it past the wait',
        () async {
          final name = WebWasmExecutorFactory.databaseName(_uniqueServerId());
          await _holdLock(WebLocksDatabaseExclusivity.lockName(name));

          final hold = await const WebLocksDatabaseExclusivity().acquire(
            name,
            wait: const Duration(milliseconds: 100),
          );

          expect(hold, isA<WebDatabaseHeldElsewhere>());
        },
      );

      test('a request that gave up leaves nothing queued behind it', () async {
        // A request left in the queue would be granted once the other holder
        // lets go, and then hold the database for good: this tab's own Retry
        // would find it held elsewhere.
        final name = WebWasmExecutorFactory.databaseName(_uniqueServerId());
        final release = await _holdLock(
          WebLocksDatabaseExclusivity.lockName(name),
        );
        const exclusivity = WebLocksDatabaseExclusivity();
        expect(
          await exclusivity.acquire(
            name,
            wait: const Duration(milliseconds: 100),
          ),
          isA<WebDatabaseHeldElsewhere>(),
        );

        release();
        final retry = await exclusivity.acquire(
          name,
          wait: const Duration(milliseconds: 500),
        );

        expect(retry, isA<WebDatabaseHeld>());
        (retry as WebDatabaseHeld).release();
      });

      test('a hold released within the wait is granted', () async {
        // A reload: the new page asks while the old one is still letting go.
        final name = WebWasmExecutorFactory.databaseName(_uniqueServerId());
        final release = await _holdLock(
          WebLocksDatabaseExclusivity.lockName(name),
        );
        Timer(const Duration(milliseconds: 20), release);

        final hold = await const WebLocksDatabaseExclusivity().acquire(
          name,
          wait: const Duration(milliseconds: 500),
        );

        expect(hold, isA<WebDatabaseHeld>());
        (hold as WebDatabaseHeld).release();
      });

      test('release frees it for the next acquire', () async {
        final name = WebWasmExecutorFactory.databaseName(_uniqueServerId());
        const exclusivity = WebLocksDatabaseExclusivity();
        const wait = Duration(milliseconds: 100);

        final first = await exclusivity.acquire(name, wait: wait);
        expect(first, isA<WebDatabaseHeld>());
        expect(
          await exclusivity.acquire(name, wait: wait),
          isA<WebDatabaseHeldElsewhere>(),
          reason: 'the first hold is exclusive while it lasts',
        );

        (first as WebDatabaseHeld).release();
        final next = await exclusivity.acquire(name, wait: wait);

        expect(next, isA<WebDatabaseHeld>());
        (next as WebDatabaseHeld).release();
      });

      test('a lock request that fails for another reason is unavailable, '
          'so the tab opens as before', () async {
        // Only the wait running out means another tab holds the database.
        final locks = _rejectingLocks(
          web.DOMException('the lock manager is gone', 'InvalidStateError'),
        );

        final hold = await WebLocksDatabaseExclusivity(locks: locks).acquire(
          WebWasmExecutorFactory.databaseName(_uniqueServerId()),
          wait: const Duration(milliseconds: 100),
        );

        expect(hold, isA<WebDatabaseHoldUnavailable>());
      });
    });

    group('WebStorageInstaller', () {
      test('a second install while the first holds the database throws '
          'WebDatabaseInUse and runs no statement', () async {
        final serverId = _uniqueServerId();
        final first = DependencyContainerImpl();
        addTearDown(first.dispose);
        await WebStorageInstaller(
          factory: _opensAs(WasmStorageImplementation.unsafeIndexedDb),
        ).install(first, _identity(serverId));

        final counting = _CountingInterceptor();
        final second = DependencyContainerImpl();
        addTearDown(second.dispose);
        await expectLater(
          WebStorageInstaller(
            factory: _opensAs(
              WasmStorageImplementation.unsafeIndexedDb,
              interceptor: counting,
            ),
            exclusiveWait: const Duration(milliseconds: 100),
          ).install(second, _identity(serverId)),
          throwsA(
            isA<WebDatabaseInUse>().having(
              (inUse) => inUse.databaseName,
              'databaseName',
              WebWasmExecutorFactory.databaseName(serverId),
            ),
          ),
        );

        // Nothing opened it, so nothing read the stored file, and nothing
        // could write a stale copy back.
        expect(counting.opens, 0);
        expect(counting.statements, 0);
        expect(counting.closes, 1, reason: 'the connection is closed unused');
        expect(second.isRegistered<ServerDatabase>(), isFalse);
      });

      test('disposing the holder lets the next install open', () async {
        final serverId = _uniqueServerId();
        final first = DependencyContainerImpl();
        await WebStorageInstaller(
          factory: _opensAs(WasmStorageImplementation.unsafeIndexedDb),
        ).install(first, _identity(serverId));
        await first.dispose();

        final second = DependencyContainerImpl();
        addTearDown(second.dispose);
        await WebStorageInstaller(
          factory: _opensAs(WasmStorageImplementation.unsafeIndexedDb),
          exclusiveWait: const Duration(milliseconds: 500),
        ).install(second, _identity(serverId));

        final db = second.get<ServerDatabase>();
        expect(await db.customSelect('SELECT 1').get(), isNotEmpty);
      });

      test('the hold lasts until the scope is disposed', () async {
        final serverId = _uniqueServerId();
        final exclusivity = _FakeExclusivity();
        final container = DependencyContainerImpl();
        await WebStorageInstaller(
          factory: _opensAs(WasmStorageImplementation.unsafeIndexedDb),
          exclusivity: exclusivity,
        ).install(container, _identity(serverId));

        expect(exclusivity.acquired, [
          WebWasmExecutorFactory.databaseName(serverId),
        ]);
        expect(exclusivity.releases, 0);

        await container.dispose();

        expect(exclusivity.releases, 1);
      });

      test('a failed open releases the hold', () async {
        // Kept, the hold would lock this tab out of its own Retry, which
        // would show "open in another tab" for good.
        final exclusivity = _FakeExclusivity();
        final container = DependencyContainerImpl();
        addTearDown(container.dispose);

        await expectLater(
          WebStorageInstaller(
            factory: _opensAs(
              WasmStorageImplementation.unsafeIndexedDb,
              engineUri: Uri.parse('missing-sqlite3.wasm'),
            ),
            exclusivity: exclusivity,
          ).install(container, _identity(_uniqueServerId())),
          throwsA(isA<DriftRemoteException>()),
        );

        expect(exclusivity.acquired, hasLength(1));
        expect(exclusivity.releases, 1);
        expect(container.isRegistered<ServerDatabase>(), isFalse);
      });

      test('a failed registration releases the hold', () async {
        final exclusivity = _FakeExclusivity();
        final container = DependencyContainerImpl();
        await container.dispose();

        await expectLater(
          WebStorageInstaller(
            factory: _opensAs(WasmStorageImplementation.unsafeIndexedDb),
            exclusivity: exclusivity,
          ).install(container, _identity(_uniqueServerId())),
          throwsStateError,
        );

        expect(exclusivity.acquired, hasLength(1));
        expect(exclusivity.releases, 1);
      });

      test('durable and in-memory storage take no hold', () async {
        for (final implementation in [
          WasmStorageImplementation.opfsShared,
          WasmStorageImplementation.opfsLocks,
          WasmStorageImplementation.sharedIndexedDb,
          WasmStorageImplementation.inMemory,
        ]) {
          final exclusivity = _FakeExclusivity();
          final container = DependencyContainerImpl();
          addTearDown(container.dispose);

          await WebStorageInstaller(
            factory: _opensAs(implementation),
            exclusivity: exclusivity,
          ).install(container, _identity(_uniqueServerId()));

          expect(
            exclusivity.acquired,
            isEmpty,
            reason: '${implementation.name} took a hold',
          );
          expect(container.isRegistered<ServerDatabase>(), isTrue);
          // One ServerDatabase open at a time, or drift warns of a second.
          await container.dispose();
        }
      });

      test('without Web Locks it opens as before', () async {
        final exclusivity = _FakeExclusivity(available: false);
        final container = DependencyContainerImpl();
        addTearDown(container.dispose);

        await WebStorageInstaller(
          factory: _opensAs(WasmStorageImplementation.unsafeIndexedDb),
          exclusivity: exclusivity,
        ).install(container, _identity(_uniqueServerId()));

        expect(exclusivity.acquired, hasLength(1));
        final db = container.get<ServerDatabase>();
        expect(await db.customSelect('SELECT 1').get(), isNotEmpty);
      });
    });
  });

  // ── #442: what one tab writes, another tab's streams hear ───────────────
  //
  // Each tab holds its own connection to the server's database, and a screen
  // in one must hear what the other writes. Drift relays it in every durable
  // mode, by the shared worker or a `BroadcastChannel`; these pin it for the
  // mode this harness gets (see the header), not for every mode.
  group('two connections to one database (#442)', () {
    Future<(ServerDatabase, ServerDatabase)> openTwice() async {
      // Two databases, each on its own executor: not the race drift warns
      // of.
      final warned = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
      driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
      addTearDown(
        () => driftRuntimeOptions.dontWarnAboutMultipleDatabases = warned,
      );
      final serverId = _uniqueServerId();
      final dbs = <ServerDatabase>[];
      for (var i = 0; i < 2; i++) {
        final opening = await const WebWasmExecutorFactory().serverDatabase(
          serverId,
        );
        final db = ServerDatabase(opening.executor, enableWriteAheadLog: false);
        addTearDown(db.close);
        dbs.add(db);
      }
      return (dbs[0], dbs[1]);
    }

    test('a write through one re-runs a stream query on the other', () async {
      final (writer, watcher) = await openTwice();
      final seen = <List<String>>[];
      final sub = GameRepositoryImpl(
        watcher,
        userId: _kUserId,
      ).watchGames().listen((games) => seen.add([for (final g in games) g.id]));
      addTearDown(sub.cancel);
      await _eventually(() => seen.isNotEmpty);
      expect(seen.single, isEmpty);

      await GameRepositoryImpl(
        writer,
        userId: _kUserId,
      ).cacheGame(_game(title: 'Relayed'));

      await _eventually(() => seen.length > 1);
      expect(seen.last, ['g-1']);
    });

    test('a household reconciled through one is followed through the other, '
        'on the emission that drops the local row', () async {
      final (writer, watcher) = await openTwice();
      HouseholdRepositoryImpl repositoryOver(ServerDatabase db) {
        const clock = LocalClockService();
        return HouseholdRepositoryImpl(
          db: db,
          currentUserId: () => 'user-1',
          syncQueue: SyncQueueRepositoryImpl(db, clock, userId: 'user-1'),
          clock: clock,
        );
      }

      final here = repositoryOver(writer);
      final there = repositoryOver(watcher);
      final created = await here.create(name: 'Game Night HQ');
      final localId = created.household.id;

      final seen = <({List<String> ids, String? answer})>[];
      final sub = there.watchHouseholds().listen(
        (households) => seen.add((
          ids: [for (final h in households) h.id],
          answer: there.reconciledHouseholdId(localId),
        )),
      );
      addTearDown(sub.cancel);
      await _eventually(() => seen.any((s) => s.ids.contains(localId)));

      await here.reconcileCreatedHousehold(
        created.household.copyWith(
          id: 'hh_server',
          isDirty: false,
          isLocalOnly: false,
        ),
        localId: localId,
        completedSyncQueueId: created.syncQueueId,
      );

      await _eventually(() => seen.any((s) => !s.ids.contains(localId)));
      final moved = seen.firstWhere((s) => !s.ids.contains(localId));
      expect(moved.ids, ['hh_server']);
      expect(moved.answer, 'hh_server');
    });
  });
}

/// Waits for [condition], which another connection's relay makes true in
/// its own time: a message through a worker, not a microtask.
Future<void> _eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Holds [lockName] through this page's own `navigator.locks`, as another tab
/// would, from the grant until the returned function is called or the test
/// ends.
Future<void Function()> _holdLock(String lockName) async {
  final granted = Completer<void>();
  final released = Completer<void>();
  void release() {
    if (!released.isCompleted) released.complete();
  }

  web.window.navigator.locks.request(
    lockName,
    ((web.Lock? _) {
      granted.complete();
      return released.future.toJS;
    }).toJS,
  );
  addTearDown(release);
  await granted.future;
  return release;
}

/// A `LockManager` whose every request fails with [error]. The real one
/// fails only for names this code never asks for, so this is how a failure
/// that isn't the wait running out is reached.
web.LockManager _rejectingLocks(web.DOMException error) {
  final promise = globalContext['Promise']! as JSObject;
  final locks = JSObject()
    ..['request'] = ((
      JSString _,
      JSObject _,
      JSFunction _,
    ) => promise.callMethod<JSPromise<JSAny?>>('reject'.toJS, error)).toJS;
  return locks as web.LockManager;
}

/// A factory whose open reports [implementation] over a real executor for the
/// database asked for. Which mode a real open lands on is the browser's call,
/// so the installer's branches on it are reached by faking the report.
///
/// [interceptor] wraps the executor. [engineUri] replaces the `sqlite3.wasm`
/// asset, so a missing one fails the forced open.
WebWasmExecutorFactory _opensAs(
  WasmStorageImplementation implementation, {
  QueryInterceptor? interceptor,
  Uri? engineUri,
}) {
  return WebWasmExecutorFactory(
    open:
        ({
          required databaseName,
          required sqlite3Uri,
          required driftWorkerUri,
        }) async {
          final real = await WasmDatabase.open(
            databaseName: databaseName,
            sqlite3Uri: engineUri ?? sqlite3Uri,
            driftWorkerUri: driftWorkerUri,
          );
          final executor = real.resolvedExecutor;
          return WasmDatabaseResult(
            interceptor == null
                ? executor
                : executor.interceptWith(interceptor),
            implementation,
            const {MissingBrowserFeature.sharedWorkers},
          );
        },
  );
}

/// Counts what reaches the database through an executor.
final class _CountingInterceptor extends QueryInterceptor {
  /// Opens. The first is where the worker reads the stored file and runs the
  /// migrations.
  int opens = 0;

  /// Statements of every kind, inside transactions too.
  int statements = 0;

  int closes = 0;

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) {
    opens++;
    return super.ensureOpen(executor, user);
  }

  @override
  Future<void> close(QueryExecutor inner) {
    closes++;
    return super.close(inner);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    this.statements++;
    return super.runBatched(executor, statements);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    statements++;
    return super.runCustom(executor, statement, args);
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    statements++;
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    statements++;
    return super.runUpdate(executor, statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    statements++;
    return super.runDelete(executor, statement, args);
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    statements++;
    return super.runSelect(executor, statement, args);
  }
}

/// Grants every hold, or with [available] false answers that this browser
/// context has no Web Locks, and records what was asked for and given back.
final class _FakeExclusivity implements WebDatabaseExclusivity {
  _FakeExclusivity({this.available = true});

  final bool available;

  /// The database names asked for, in order.
  final acquired = <String>[];

  /// How many times a hold this granted was given back.
  int releases = 0;

  @override
  Future<WebDatabaseHold> acquire(
    String databaseName, {
    required Duration wait,
  }) async {
    acquired.add(databaseName);
    return available
        ? WebDatabaseHeld(() => releases++)
        : const WebDatabaseHoldUnavailable();
  }
}
