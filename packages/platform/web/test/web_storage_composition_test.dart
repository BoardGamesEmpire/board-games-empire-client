// The browser-only half of the composition root (#288).
//
// Browser-only because that is what it *is*: this file imports
// `web_storage_composition.dart`, which reaches `dart:js_interop`. That is
// also the boundary this suite exists to keep visible — every other suite in
// this package runs on the VM, and would stop compiling if the composition
// leaked back into `web.dart`.
//
// Run with `melos run test:web` (`flutter test --platform chrome`).
@TestOn('browser')
library;

import 'dart:async';

import 'package:app_shell/app_shell.dart' show LocalDataInUseError;
import 'package:bge_test_support/domain.dart';
import 'package:di/di.dart';
import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/wasm.dart'
    show
        MissingBrowserFeature,
        WasmDatabase,
        WasmDatabaseResult,
        WasmStorageImplementation;
import 'package:drift_storage/drift_storage.dart' show ServerDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart' show UserSessionScope;
import 'package:interfaces/portability.dart' show UserDataExportSink;
import 'package:interfaces/repositories.dart' show AuthRepository;
import 'package:interfaces/services.dart';
import 'package:interfaces/sync.dart' show CrossTabLock;
import 'package:logging/logging.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart' show ServerIdentity;
import 'package:network_interface/network_interface.dart'
    show HouseholdRemoteDataSource;
import 'package:observability/observability.dart';
import 'package:web_network/web_network.dart' show WebAuthRepositoryImpl;
import 'package:web_platform/web.dart';
import 'package:web_platform/web_storage_composition.dart';
import 'package:web_storage/web_storage.dart';

import 'support/web_origin.dart';

void main() {
  group('bgeWebPlatformBootstrap', () {
    test('is a WebPlatformBootstrap that can reset its storage', () {
      expect(bgeWebPlatformBootstrap(), isA<WebPlatformBootstrap>());
      expect(bgeWebPlatformBootstrap().supportsReset, isTrue);
    });

    test("leaves Back to the browser's own (#611)", () {
      expect(bgeWebPlatformBootstrap().browserOwnsBack, isTrue);
    });

    test('initialize() builds the scope with web storage, the per-user tier '
        "and the origin's remotes (#325)", () async {
      // Until this test, dropping `serverScopeBuilder` from
      // `bgeWebPlatformBootstrap` (or `installStorage` / `userInstallers` from
      // the scope it builds) passed every suite: the app would boot with no
      // database or no per-user tier. Only the well-known client and the
      // origin are faked; everything the scope installs is real.
      //
      // A fresh server id: the web database is named by it, and IndexedDB
      // outlives the test.
      final bootstrap = bgeWebPlatformBootstrap(
        wellKnownClient: wellKnownAnswering(freshIdentity('web-bootstrap')),
        originProvider: () => kWebTestOrigin,
      );
      addTearDown(bootstrap.dispose);

      final result = await bootstrap.initialize();
      final container = result.activeServerScope!.active!.container;

      expect(container.isRegistered<ServerDatabase>(), isTrue);
      expect(container.isRegistered<UserSessionScope>(), isTrue);
      expect(container.isRegistered<HouseholdRemoteDataSource>(), isTrue);
      expect(container.isRegistered<CrossTabLock>(), isTrue);
      expect(container.get<AuthRepository>(), isA<WebAuthRepositoryImpl>());
    });

    test('its root container carries the DURABLE feedback sink, not the '
        'stand-in (#292)', () async {
      // The one assertion that catches the wiring mistake this composition
      // exists to prevent: `WebPlatformBootstrap()` still builds a
      // perfectly valid root container, just with a sink that forgets
      // everything on reload.
      final container = await bgeWebPlatformBootstrap().createRootContainer();
      addTearDown(container.dispose);

      expect(container.get<FeedbackSink>(), isA<IndexedDbFeedbackSink>());
    });
  });

  group('buildWebRootModule', () {
    test('registers a sink whose records survive the container being torn '
        'down and rebuilt', () async {
      final container = DependencyContainerImpl();
      await buildWebRootModule(container);
      // This is the one test that writes to the *production* database name,
      // because that is what `buildWebRootModule` opens. Clean up through a
      // tear-down rather than the success path: a record left behind by a
      // failing run would make the next run pass on the previous run's data.
      addTearDown(() async {
        final sink = await IndexedDbFeedbackSink.open();
        await sink.remove('composition-round-trip');
        await sink.onDispose();
      });
      final record = QueuedFeedbackReport(
        report: const FeedbackReport(
          category: FeedbackCategory.bug,
          severity: FeedbackSeverity.low,
          message: 'approved while the boot was failing',
          clientRequestId: 'composition-round-trip',
        ),
        queuedAt: DateTime.utc(2026, 9, 20),
      );
      await container.get<FeedbackSink>().persist(record);
      // Closes the IndexedDB connection, the way a reload would.
      await container.dispose();

      final rebuilt = DependencyContainerImpl();
      addTearDown(rebuilt.dispose);
      await buildWebRootModule(rebuilt);
      final pending = await rebuilt.get<FeedbackSink>().pending();

      expect(
        pending.map((r) => r.storageKey),
        contains('composition-round-trip'),
      );
    });

    test('registers a device reader fed by the browser it runs in '
        '(#324)', () async {
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);

      await buildWebRootModule(container);
      final info = container.get<DeviceInfoReader>().read();

      // The host OS varies by machine; what is pinned is that it reads as one
      // of the values the reader can report.
      expect(
        info['operatingSystem'],
        isIn(['android', 'iOS', 'macOS', 'windows', 'linux', 'unknown']),
      );
      // This suite only runs in Chrome.
      expect(info['browserEngine'], 'blink');
      expect(info['browser'], startsWith('Chrome '));
    });

    test("registers the export's download sink (#92)", () async {
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);

      await buildWebRootModule(container);

      expect(
        container.get<UserDataExportSink>(),
        isA<DownloadUserDataExportSink>(),
      );
    });
  });

  group('reportWebStorage', () {
    late List<LogRecord> records;
    late StreamSubscription<LogRecord> subscription;

    setUp(() {
      records = [];
      Logger.root.level = Level.ALL;
      subscription = Logger.root.onRecord.listen(records.add);
    });

    tearDown(() async {
      await subscription.cancel();
      Logger.root.level = Level.INFO;
    });

    WebDatabaseOpening opening(WasmStorageImplementation implementation) =>
        WebDatabaseOpening(
          // Never touched: reporting reads the implementation and the
          // missing-feature set, never the connection.
          executor: _UnusedExecutor(),
          implementation: implementation,
          missingFeatures: const {},
        );

    test('a durable browser is recorded, not warned about', () {
      reportWebStorage(opening(WasmStorageImplementation.opfsShared));

      expect(records, hasLength(1));
      expect(records.single.level, Level.INFO);
      expect(records.single.message, contains('opfsShared'));
    });

    test('racy storage warns', () {
      reportWebStorage(opening(WasmStorageImplementation.unsafeIndexedDb));

      expect(records.single.level, Level.WARNING);
      expect(records.single.message, contains('second tab'));
      // #686: one tab at a time when the browser grants the Web Lock, and
      // otherwise each tab has its own copy, so no lock keeps the sync queue
      // from sending an op twice or out of order.
      expect(records.single.message, contains('only one tab at a time'));
      expect(records.single.message, contains('grants this tab its Web Lock'));
      expect(records.single.message, contains('separate warning'));
      expect(records.single.message, contains('sync queue'));
      expect(records.single.message, contains('twice or out of order'));
    });

    test('storage that persists nothing is an error, but does not throw', () {
      // Deliberately not fatal: web's server is the serving origin and is
      // reachable by construction, so an app with no cache still works.
      reportWebStorage(opening(WasmStorageImplementation.inMemory));

      expect(records.single.level, Level.SEVERE);
      expect(records.single.message, contains('nothing is being persisted'));
    });
  });

  group('installWebStorage', () {
    test(
      "registers the database and the drain's CrossTabLock (#447)",
      () async {
        // The server scope installs storage through this function, so removing
        // its lock registration leaves the web drain unlocked with nothing else
        // failing. The test page is served from localhost, a secure context,
        // so the real check finds Web Locks.
        final container = DependencyContainerImpl();
        addTearDown(container.dispose);

        await installWebStorage(
          container,
          _identity('srv-${DateTime.now().microsecondsSinceEpoch}'),
        );

        expect(container.isRegistered<ServerDatabase>(), isTrue);
        expect(container.get<CrossTabLock>(), isA<WebCrossTabLock>());
      },
    );

    test('a database another tab holds fails the install with '
        'LocalDataInUseError (#686)', () async {
      // The in-use screen is the bootstrap's answer to this error, and it
      // keeps the reset offer away from it. The typed error the storage layer
      // throws is no use to that screen until it is mapped here.
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);
      final serverId = 'srv-${DateTime.now().microsecondsSinceEpoch}';

      await expectLater(
        installWebStorage(
          container,
          _identity(serverId),
          installer: WebStorageInstaller(
            factory: _opensOnUnsafeIndexedDb(),
            exclusivity: const _HeldElsewhere(),
            exclusiveWait: const Duration(milliseconds: 100),
          ),
        ),
        throwsA(isA<LocalDataInUseError>()),
      );

      expect(container.isRegistered<ServerDatabase>(), isFalse);
      expect(container.isRegistered<CrossTabLock>(), isFalse);
    });
  });

  group('WarnedWebDatabaseExclusivity', () {
    late List<LogRecord> records;
    late StreamSubscription<LogRecord> subscription;

    setUp(() {
      records = [];
      Logger.root.level = Level.ALL;
      subscription = Logger.root.onRecord
          .where((r) => r.loggerName == 'bge.platform.web_storage')
          .listen(records.add);
    });

    tearDown(() async {
      await subscription.cancel();
      Logger.root.level = Level.INFO;
    });

    Future<WebDatabaseHold> acquireThrough(WebDatabaseHold answer) {
      return WarnedWebDatabaseExclusivity(
        _Answering(answer),
      ).acquire('db', wait: const Duration(milliseconds: 100));
    }

    test('warns once, and passes the answer through, when no hold can be '
        'taken (#686)', () async {
      const unavailable = WebDatabaseHoldUnavailable();

      final hold = await acquireThrough(unavailable);

      expect(hold, same(unavailable));
      expect(records, hasLength(1));
      expect(records.single.level, Level.WARNING);
      expect(records.single.message, contains('without the one-tab hold'));
      expect(records.single.message, contains('Web Locks'));
      expect(records.single.message, contains('another tab'));
    });

    test('says nothing when the hold is taken', () async {
      var released = false;
      final held = WebDatabaseHeld(() => released = true);

      final hold = await acquireThrough(held);
      (hold as WebDatabaseHeld).release();

      expect(hold, same(held));
      expect(released, isTrue);
      expect(records, isEmpty);
    });

    test('says nothing when another tab holds the database', () async {
      const elsewhere = WebDatabaseHeldElsewhere();

      final hold = await acquireThrough(elsewhere);

      expect(hold, same(elsewhere));
      expect(records, isEmpty);
    });
  });

  group('registerWebCrossTabLock', () {
    late List<LogRecord> records;
    late StreamSubscription<LogRecord> subscription;

    setUp(() {
      records = [];
      Logger.root.level = Level.ALL;
      subscription = Logger.root.onRecord
          .where((r) => r.loggerName == 'bge.platform.web_storage')
          .listen(records.add);
    });

    tearDown(() async {
      await subscription.cancel();
      Logger.root.level = Level.INFO;
    });

    test("registers the Web Lock as the drain's CrossTabLock (#447)", () {
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);

      registerWebCrossTabLock(container, locksAvailable: () => true);

      expect(container.get<CrossTabLock>(), isA<WebCrossTabLock>());
      expect(records, isEmpty);
    });

    test('without Web Locks registers nothing, and warns once that the drain '
        'runs unlocked', () {
      // A plain-http self-hosted origin: `navigator.locks` only exists in a
      // secure context. The app still boots and drains.
      final container = DependencyContainerImpl();
      addTearDown(container.dispose);

      registerWebCrossTabLock(container, locksAvailable: () => false);

      expect(container.isRegistered<CrossTabLock>(), isFalse);
      expect(records, hasLength(1));
      expect(records.single.level, Level.WARNING);
      expect(
        records.single.message,
        'no Web Locks in this browser context; the sync drain runs without a '
        'cross-tab lock',
      );
    });
  });
}

/// Only [ServerIdentity.serverId] matters here, as the database name derives
/// from it.
ServerIdentity _identity(String serverId) =>
    testServerIdentity().copyWith(serverId: serverId);

/// The report never queries; a mock keeps this suite from needing a real
/// database to assert a log level.
class _UnusedExecutor extends Mock implements QueryExecutor {}

/// A factory whose open really opens the wasm database, and reports that it
/// landed on `unsafeIndexedDb`, as a browser without shared workers does.
WebWasmExecutorFactory _opensOnUnsafeIndexedDb() => WebWasmExecutorFactory(
  open:
      ({
        required databaseName,
        required sqlite3Uri,
        required driftWorkerUri,
      }) async {
        final real = await WasmDatabase.open(
          databaseName: databaseName,
          sqlite3Uri: sqlite3Uri,
          driftWorkerUri: driftWorkerUri,
        );
        return WasmDatabaseResult(
          real.resolvedExecutor,
          WasmStorageImplementation.unsafeIndexedDb,
          const {MissingBrowserFeature.sharedWorkers},
        );
      },
);

/// Another tab holds every database for the whole wait.
final class _HeldElsewhere implements WebDatabaseExclusivity {
  const _HeldElsewhere();

  @override
  Future<WebDatabaseHold> acquire(
    String databaseName, {
    required Duration wait,
  }) async => const WebDatabaseHeldElsewhere();
}

/// Answers every request with [answer].
final class _Answering implements WebDatabaseExclusivity {
  const _Answering(this.answer);

  final WebDatabaseHold answer;

  @override
  Future<WebDatabaseHold> acquire(
    String databaseName, {
    required Duration wait,
  }) async => answer;
}
