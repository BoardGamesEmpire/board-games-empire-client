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

import 'package:di/di.dart';
import 'package:drift/drift.dart' show QueryExecutor;
import 'package:drift/wasm.dart' show WasmStorageImplementation;
import 'package:drift_storage/drift_storage.dart' show ServerDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart' show UserSessionScope;
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
    test('is a WebPlatformBootstrap that cannot reset', () {
      expect(bgeWebPlatformBootstrap(), isA<WebPlatformBootstrap>());
      expect(bgeWebPlatformBootstrap().supportsReset, isFalse);
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
      // #447: the drain runs on this mode too, under the same lock, and can
      // still race another tab's inline send.
      expect(records.single.message, contains('sync drain'));
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

/// Shaped like `testServerIdentity` in `core/di`'s fixtures; only
/// [ServerIdentity.serverId] matters here, as the database name derives from
/// it.
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

/// The report never queries; a mock keeps this suite from needing a real
/// database to assert a log level.
class _UnusedExecutor extends Mock implements QueryExecutor {}
