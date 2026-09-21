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
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:observability/observability.dart';
import 'package:mocktail/mocktail.dart';
import 'package:web_platform/web.dart';
import 'package:web_platform/web_storage_composition.dart';
import 'package:web_storage/web_storage.dart';

void main() {
  group('bgeWebPlatformBootstrap', () {
    test('is a WebPlatformBootstrap with the storage-composed scope', () {
      // The wiring the app depends on. `const WebPlatformBootstrap()` would
      // also boot — without a database — so what matters is that the app has
      // a single named thing to reach for, and that it is this type.
      expect(bgeWebPlatformBootstrap(), isA<WebPlatformBootstrap>());
      expect(bgeWebPlatformBootstrap().supportsReset, isFalse);
    });

    test('its root container carries the DURABLE feedback sink, not the '
        'stand-in (#292)', () async {
      // The one assertion that catches the wiring mistake this composition
      // exists to prevent: `const WebPlatformBootstrap()` still builds a
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
    });

    test('storage that persists nothing is an error, but does not throw', () {
      // Deliberately not fatal: web's server is the serving origin and is
      // reachable by construction, so an app with no cache still works.
      reportWebStorage(opening(WasmStorageImplementation.inMemory));

      expect(records.single.level, Level.SEVERE);
      expect(records.single.message, contains('nothing is being persisted'));
    });
  });
}

/// The report never queries; a mock keeps this suite from needing a real
/// database to assert a log level.
class _UnusedExecutor extends Mock implements QueryExecutor {}
