// The browser end of the web reset (#793): a stored database that won't open,
// offered for deletion on the failure screen, deleted, and opened again.
@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:app_shell/app_shell.dart';
import 'package:drift_storage/drift_storage.dart' show ServerDatabase;
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:web_platform/web_storage_composition.dart';
import 'package:web_storage/web_storage.dart';

import 'support/web_origin.dart';

/// The #608 state: a stored file whose schema version reads 0 while its
/// tables exist, so the next open runs `onCreate` over them and fails.
Future<void> _breakStoredDatabase(String serverId) async {
  final opening = await const WebWasmExecutorFactory().serverDatabase(serverId);
  final db = ServerDatabase(opening.executor, enableWriteAheadLog: false);
  await db.customSelect('SELECT 1').get();
  await db.customStatement('PRAGMA user_version = 0');
  await db.close();
}

/// Holds a raw IndexedDB connection to [name] open until the test ends, the
/// way another tab's open database would be.
Future<void> _holdConnection(String name) async {
  final opened = Completer<web.IDBDatabase>();
  final request = web.window.indexedDB.open(name);
  request.onsuccess = ((web.Event _) {
    opened.complete(request.result! as web.IDBDatabase);
  }).toJS;
  final held = await opened.future;
  // ignore: unnecessary_lambdas, interop members can't be torn off.
  addTearDown(() => held.close());
}

void main() {
  group('WasmServerDatabaseReset', () {
    test('answers only a stored database that failed to open', () {
      const reset = WasmServerDatabaseReset();

      expect(reset.answers(WebDatabaseOpenFailure(StateError('x'))), isTrue);
      expect(reset.answers(StateError('x')), isFalse);
    });

    test('deleteAll with nothing stored completes', () async {
      await const WasmServerDatabaseReset(
        namePrefix: 'bge_server_no_such_database_',
      ).deleteAll();
    });

    test('deleteAll throws LocalDataInUseError, promptly, when another '
        'connection holds a database open', () async {
      final name = WebWasmExecutorFactory.databaseName(
        freshIdentity('web-reset-held').serverId,
      );
      await _holdConnection(name);

      await expectLater(
        WasmServerDatabaseReset(namePrefix: name).deleteAll().timeout(
          const Duration(seconds: 10),
        ),
        throwsA(isA<LocalDataInUseError>()),
      );
    });
  });

  test("a stored database that won't open is offered, deleted and reopened "
      '(#793)', () async {
    final id = freshIdentity('web-reset');
    await _breakStoredDatabase(id.serverId);

    final bootstrap = bgeWebPlatformBootstrap(
      wellKnownClient: wellKnownAnswering(id),
      originProvider: () => kWebTestOrigin,
      storageReset: WasmServerDatabaseReset(
        namePrefix: WebWasmExecutorFactory.databaseName(id.serverId),
      ),
    );
    addTearDown(bootstrap.dispose);
    final cubit = AppBootstrapCubit(
      platformBootstrap: bootstrap,
      hydratedStorageInitializer: (_) async {},
    );
    addTearDown(cubit.close);

    await cubit.initialize();
    await cubit.retry();
    await cubit.retry();

    expect(cubit.state, isA<AppBootstrapFailed>());
    expect((cubit.state as AppBootstrapFailed).canOfferReset, isTrue);

    await cubit.resetAndRetry();

    expect(cubit.state, isA<AppBootstrapNeedsAuth>());
  });
}
