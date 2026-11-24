// The VM half of the persistent-storage request (#320): the browser's two
// calls come in as functions, so the asking, the once-only and the logging
// are assertable without a browser.
@TestOn('vm')
library;

import 'dart:async';

import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart'
    show DependencyContainer, UserScopeInstaller;
import 'package:logging/logging.dart';
import 'package:models/domain.dart' show ScopedServer;
import 'package:web_platform/web.dart';

void main() {
  group('PersistentStorageRequest', () {
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

    test('does not ask persist when storage is already persistent', () async {
      var persistCalls = 0;
      final request = PersistentStorageRequest(
        persisted: () async => true,
        persist: () async {
          persistCalls++;
          return true;
        },
      );

      await request.requestOnce();

      expect(persistCalls, 0);
      expect(records, hasLength(1));
      expect(records.single.level, Level.INFO);
    });

    test('asks persist when not yet persistent, and logs a grant at '
        'info', () async {
      var persistCalls = 0;
      final request = PersistentStorageRequest(
        persisted: () async => false,
        persist: () async {
          persistCalls++;
          return true;
        },
      );

      await request.requestOnce();

      expect(persistCalls, 1);
      expect(records, hasLength(1));
      expect(records.single.level, Level.INFO);
    });

    test('logs a refusal at warn', () async {
      final request = PersistentStorageRequest(
        persisted: () async => false,
        persist: () async => false,
      );

      await request.requestOnce();

      expect(records, hasLength(1));
      expect(records.single.level, Level.WARNING);
    });

    test('asks once: a second requestOnce returns the same future and calls '
        'nothing', () async {
      var persistedCalls = 0;
      var persistCalls = 0;
      final request = PersistentStorageRequest(
        persisted: () async {
          persistedCalls++;
          return false;
        },
        persist: () async {
          persistCalls++;
          return true;
        },
      );

      final first = request.requestOnce();
      final second = request.requestOnce();
      await first;

      expect(identical(first, second), isTrue);
      await request.requestOnce();
      expect(persistedCalls, 1);
      expect(persistCalls, 1);
      expect(records, hasLength(1));
    });

    test('a throwing check is logged, not thrown', () async {
      final request = PersistentStorageRequest(
        persisted: () async => throw StateError('no storage'),
        persist: () async => true,
      );

      await request.requestOnce();

      expect(records, hasLength(1));
      expect(records.single.level, Level.WARNING);
      expect(records.single.error, isA<StateError>());
    });

    test('a throwing persist is logged, not thrown', () async {
      final request = PersistentStorageRequest(
        persisted: () async => false,
        persist: () async => throw StateError('no storage'),
      );

      await request.requestOnce();

      expect(records, hasLength(1));
      expect(records.single.level, Level.WARNING);
    });
  });

  group('PersistentStorageRequestInstaller', () {
    late DependencyContainer container;

    setUp(() {
      container = DependencyContainerImpl();
      addTearDown(container.dispose);
    });

    test("install doesn't wait for the request", () async {
      final never = Completer<void>();
      final UserScopeInstaller installer = PersistentStorageRequestInstaller(
        () => never.future,
      );

      await installer.install(container, _server, 'user-1');
    });

    test("a request that throws doesn't fail install", () async {
      final UserScopeInstaller installer = PersistentStorageRequestInstaller(
        () async => throw StateError('boom'),
      );

      await installer.install(container, _server, 'user-1');
      await Future<void>.delayed(Duration.zero);
    });

    test('a request that throws synchronously does not fail install', () async {
      final UserScopeInstaller installer = PersistentStorageRequestInstaller(
        () => throw StateError('boom'),
      );

      await installer.install(container, _server, 'user-1');
    });
  });
}

const _server = ScopedServer(serverId: 'server-1', displayName: 'My Server');
