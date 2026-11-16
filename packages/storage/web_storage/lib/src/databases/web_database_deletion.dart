import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:drift/wasm.dart';
import 'package:web/web.dart' as web;

import 'package:web_storage/src/databases/wasm_executor_factory.dart';

/// What [deleteServerDatabases] did (#793).
final class WebDatabaseDeletion {
  /// Creates a result.
  const WebDatabaseDeletion({required this.deleted, required this.blocked});

  /// Names of the databases that are gone.
  final List<String> deleted;

  /// Names of the databases another connection holds open. Their delete
  /// stays queued in the browser and completes once those connections close.
  final List<String> blocked;
}

/// Deletes every server database this origin holds (#793): each name
/// starting with [namePrefix], which defaults to `bge_server_`. Nothing else
/// at the origin is touched, the HydratedBloc box included.
///
/// IndexedDB databases are listed with `indexedDB.databases()` and deleted
/// with our own request. drift's `WasmDatabase.probe` doesn't list them when
/// called without a name, and its delete helper never completes while another
/// connection is open and then raises an unhandled `InvalidStateError`. A
/// browser without `databases()` (Firefox before 126) can't list them, so the
/// IndexedDB half is skipped there, as drift's probe skips it. Firefox stores
/// its databases in OPFS, which the second half still sweeps.
///
/// Each delete waits up to [blockedAfter] for another connection to let go,
/// then reports the name in [WebDatabaseDeletion.blocked] and leaves the
/// request queued in the browser. The wait is what lets drift's shared
/// worker close a database the page has only just closed. IndexedDB queues
/// requests per name, so later opens and deletes of that name, in any tab,
/// wait behind a queued one, and a later delete fires no event of its own;
/// the limit bounds those too. The deletes run together, so the limit bounds
/// the whole IndexedDB half, however many databases there are. A real delete
/// of a server database completes in milliseconds; a slow one reported
/// blocked costs a retry, which then finds it done.
///
/// OPFS databases come from `WasmDatabase.probe(...).existingDatabases` and
/// are deleted through that probe. drift swallows the errors OPFS raises for
/// a database another tab holds open, so a delete's survival is how a held
/// database is detected: after the deletes, the probe is read again and any
/// prefixed name still listed is reported blocked. Other errors propagate.
Future<WebDatabaseDeletion> deleteServerDatabases({
  String? namePrefix,
  Uri? sqlite3Uri,
  Uri? driftWorkerUri,
  Duration blockedAfter = const Duration(seconds: 3),
}) async {
  final prefix = namePrefix ?? '${WebWasmExecutorFactory.databaseNamePrefix}_';
  final sqlite3 = sqlite3Uri ?? WebWasmExecutorFactory.defaultSqlite3Uri;
  final driftWorker =
      driftWorkerUri ?? WebWasmExecutorFactory.defaultDriftWorkerUri;
  final deleted = <String>[];
  final blocked = <String>[];

  final indexedDb = web.window.indexedDB;
  if (indexedDb.has('databases')) {
    final infos = (await indexedDb.databases().toDart).toDart;
    final names = [
      for (final info in infos)
        if (info.name.startsWith(prefix)) info.name,
    ];
    final outcomes = await Future.wait([
      for (final name in names) _deleteIndexedDb(name, blockedAfter),
    ]);
    for (final (index, name) in names.indexed) {
      (outcomes[index] ? deleted : blocked).add(name);
    }
  }

  final probe = await WasmDatabase.probe(
    sqlite3Uri: sqlite3,
    driftWorkerUri: driftWorker,
  );
  final opfsNames = <String>[];
  for (final entry in probe.existingDatabases) {
    final (api, name) = entry;
    if (api == WebStorageApi.opfs && name.startsWith(prefix)) {
      await probe.deleteDatabase(entry);
      opfsNames.add(name);
    }
  }
  if (opfsNames.isNotEmpty) {
    final after = await WasmDatabase.probe(
      sqlite3Uri: sqlite3,
      driftWorkerUri: driftWorker,
    );
    final remaining = {
      for (final (api, name) in after.existingDatabases)
        if (api == WebStorageApi.opfs) name,
    };
    for (final name in opfsNames) {
      (remaining.contains(name) ? blocked : deleted).add(name);
    }
  }

  return WebDatabaseDeletion(deleted: deleted, blocked: blocked);
}

/// True once [name] is deleted, false when it is still blocked after
/// [blockedAfter]: another connection holds it, or an earlier blocked delete
/// of the name is still queued ahead of this one.
///
/// A `blocked` event is not the answer. It fires while any other connection
/// is open, and drift closes ours late: `close()` on the page only posts a
/// disconnect to the shared worker, which closes its IndexedDB connection
/// when it gets to that message. A delete right after a close, such as the
/// one after a failed open, can find the worker still holding the database.
/// The request stays queued and succeeds once the holder lets go, so this
/// waits for `success` until the time limit, whatever `blocked` said.
///
/// Completes once. A request still blocked at the limit stays queued in the
/// browser, outliving this call and the page, and fires `success` later,
/// when the other connection closes; by then the call has returned, so that
/// event, and any later `error`, is ignored.
Future<bool> _deleteIndexedDb(String name, Duration blockedAfter) {
  final done = Completer<bool>();
  final timer = Timer(blockedAfter, () {
    if (!done.isCompleted) done.complete(false);
  });
  final request = web.window.indexedDB.deleteDatabase(name);
  request
    ..onsuccess = ((web.Event _) {
      if (!done.isCompleted) done.complete(true);
    }).toJS
    ..onerror = ((web.Event _) {
      if (!done.isCompleted) {
        done.completeError(
          StateError('Deleting the database $name failed: ${request.error}'),
        );
      }
    }).toJS;
  return done.future.whenComplete(timer.cancel);
}
