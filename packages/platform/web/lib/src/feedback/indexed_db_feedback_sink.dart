import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:interfaces/orchestration.dart' show Disposable;
import 'package:observability/observability.dart';
import 'package:web/web.dart' as web;

/// Durable web [FeedbackSink] (#292): one IndexedDB record per user-approved
/// report, stored under its [QueuedFeedbackReport.storageKey] as a small
/// object, `{ageMs, json}`: the [QueuedFeedbackReport]'s JSON, and the age the
/// cap evicts by (#386).
///
/// The web counterpart of `FileFeedbackSink`, and deliberately the same
/// observable contract — only user-approved reports reach any sink (the #34
/// privacy contract is upheld by the approval gate upstream); this class just
/// makes them survive a reload until the auth-success drain can send them.
///
/// ## Why IndexedDB and not the drift/wasm data layer
///
/// #288 gave web a `ServerDatabase`, but it is registered in the **server
/// scope** and this sink is device-global: `runBgeApp` composes the
/// `FeedbackService` from the root container before any server scope exists,
/// and a report approved while bootstrap is *failing* is the first report this
/// sink will ever hold. A second, device-global drift database would answer
/// that, at the price of a second `WasmDatabase.open` — its own worker and its
/// own sqlite instance — on every authenticated session, because the drain
/// calls [pending] on every auth success. This queue is a key → JSON store of
/// at most [QueuedFeedbackReport.maxQueuedReports] records with one index, so
/// it buys nothing from a relational engine.
///
/// ## The stored value, and its one index (#386)
///
/// `json` is the record exactly as schema version 1 stored it bare, so
/// decoding never changed, and it is authoritative for everything except
/// eviction order. `ageMs` is [QueuedFeedbackReport.ageKey] in milliseconds
/// since the epoch — `0` for a record with no `queuedAt` — and the `byAge`
/// index over it is what lets the cap choose what to evict without reading a
/// single report.
///
/// An integer, and not the ISO stamp the JSON already carries, because text
/// stamps sort by time only while every one has the same precision and zone.
/// Web stamps are millisecond-precision UTC today, so text would sort
/// correctly, but by luck rather than by construction.
///
/// `ageMs` is always written. IndexedDB leaves a record out of an index when
/// the indexed property is missing, and a record outside `byAge` is one the
/// persist cap can never evict — so every write builds its value with
/// [_storedValue], which takes both properties as required arguments.
///
/// It does duplicate `queuedAt`, which is what #292 objected to in a cache of
/// stamps like native's. The difference is where the copies come from: both
/// are derived from one record and written in the same `put`, so they cannot
/// drift apart through this sink. A cache is a second store kept in step on
/// its own schedule, and so a second source of truth.
///
/// ## Operations are atomic, without a lock
///
/// Every operation runs in **one** IndexedDB `readwrite` transaction, and a
/// transaction is atomic and isolated. That is the whole of the concurrency
/// story, and it is a genuine divergence from the native sink, which needs a
/// per-instance lock because each of its operations acts on a pathname after
/// an `await`.
///
/// It is also *stronger* than that lock. Native's is per-instance and so does
/// not order this sink against another process sharing the directory; two
/// browser tabs are likewise two sink instances, but they are ordered against
/// each other by the browser, because IndexedDB's isolation is per-origin
/// rather than per-connection.
///
/// **The constraint that comes with it:** a transaction stays alive across an
/// `await` on one of its own requests, and dies across any other `await` —
/// `TransactionInactiveError`, measured, not assumed. So nothing inside
/// [_transaction] may await anything but an IndexedDB request. `jsonDecode`
/// and `jsonEncode` are safe because they are synchronous; a logger call, a
/// timer, or a `Future.delayed` would silently end the transaction and fail
/// the operation.
///
/// ## Un-drainable records are reaped, not skipped (#161)
///
/// [pending] **deletes** a record it declines to emit, for the reason the
/// native sink does: [remove] addresses a record by its storage key, so a
/// record with no key, or one whose decoded key disagrees with the key it is
/// filed under, has no address a drain could ever clear. Skipping without
/// deleting leaks it for the life of the browser profile.
///
/// What it declines, in schema version 2: a value that is not an object; an
/// object whose `json` is not a string, or will not decode; and a decoded
/// record whose `storageKey` disagrees with the key it is filed under. What
/// it never declines over is `ageMs`. Missing, non-numeric or simply wrong,
/// the record is still drainable: `ageMs` only orders eviction, and a bad one
/// must never destroy a valid report.
///
/// The transient-fault exception that native draws so carefully does not need
/// drawing here, and that is a property of the store rather than a rule this
/// class dropped. Native has to tell a locked file apart from corrupt bytes
/// because both surface as `FileSystemException`; it reads raw bytes and
/// decodes in Dart to keep them separable. IndexedDB separates them itself: a
/// store fault fails the *transaction*, so no record is examined and none is
/// deleted, while a value that will not decode has already been read
/// successfully and is corrupt by elimination.
///
/// "An unsafe storage key" — native's third reject case — has no analogue: a
/// key here is an IndexedDB key, not a path segment, so there is nothing to
/// traverse.
///
/// ## No at-rest encryption
///
/// Same posture, and the same reasoning, as the web data layer (#63): the
/// browser origin sandbox is the security boundary, and any key the page can
/// read, page-injected JavaScript can read too. Note what that means here
/// specifically — a queued report holds breadcrumbs and a last-error record,
/// so it is exactly as readable as the rest of the origin's storage.
///
/// ## Durable across reloads, not against eviction
///
/// IndexedDB lives in the origin's storage bucket, which the browser may clear
/// under storage pressure unless the origin holds a
/// `navigator.storage.persist()` grant. Nothing requests one; #320 owns that
/// decision, and it applies to this store and the `ServerDatabase` on
/// identical terms.
class IndexedDbFeedbackSink implements FeedbackSink, Disposable {
  IndexedDbFeedbackSink._(this._database, this.databaseName);

  /// The device-global database name.
  ///
  /// Not keyed by server, unlike `WebWasmExecutorFactory`'s `bge_server_*`:
  /// the queue holds reports approved when no server was active at all
  /// (`serverId == null`), which is the failed-boot case, and the drain gates
  /// on the tag rather than on which store the record came from.
  ///
  /// Effectively a storage location — changing it orphans every queued report
  /// on every existing install.
  static const String defaultDatabaseName = 'bge_feedback';

  /// The only object store. Out-of-line keys: the key is the record's
  /// [QueuedFeedbackReport.storageKey], and the value is `{ageMs, json}` —
  /// see the class doc.
  static const String _storeName = 'records';

  /// The index the persist cap walks: `ageMs` ascending, and IndexedDB breaks
  /// ties by ascending primary key.
  static const String _ageIndexName = 'byAge';

  /// The stored value's two properties; see the class doc.
  static const String _ageField = 'ageMs';
  static const String _jsonField = 'json';

  /// Version 2 (#386) stores `{ageMs, json}` and indexes `ageMs`; version 1
  /// stored the JSON bare, with no index. [open] migrates the one to the
  /// other.
  static const int _schemaVersion = 2;

  final web.IDBDatabase _database;

  /// The database this sink is connected to; injectable so browser suites,
  /// which share one origin, do not share one queue.
  final String databaseName;

  /// IndexedDB outlives a reload. The browser may still evict it; see the
  /// class doc's durability section.
  @override
  bool get survivesRestart => true;

  /// How long an open may take before the sink gives up on this browser.
  ///
  /// Matches `PackageInfoBuildInfoReader.defaultReadTimeout`, the other
  /// bootstrap-time platform read in this package, and for the same reason:
  /// the root-module contract is that a registration never throws *and never
  /// hangs*, and a bounded failure is the only way to keep the second half.
  static const Duration defaultOpenTimeout = Duration(seconds: 5);

  /// Opens the database and returns a sink over it.
  ///
  /// Opening eagerly rather than on first use is deliberate, and the opposite
  /// of `FileFeedbackSink`'s lazy directory: native defers because its default
  /// is a `path_provider` plugin call that must not run on the boot hot path,
  /// and opening IndexedDB is not a plugin call. Doing it here puts a browser
  /// that cannot provide storage in front of the bootstrap, rather than in
  /// front of the first crash report — which is the worst possible moment to
  /// discover it.
  ///
  /// Throws if the browser refuses, if the upgrade from version 1 fails, or
  /// if it does not answer within [openTimeout]. The caller decides what that
  /// means; the composition root degrades to `MemoryFeedbackSink` and says
  /// so.
  ///
  /// ## Upgrading from version 1 (#386)
  ///
  /// The upgrade adds the `byAge` index to the existing store and rewrites
  /// every version-1 text value in place as `{ageMs, json}`
  /// ([_migrateFromV1]). A value that is not text was never a record, and is
  /// left as it is for [pending] to reap. A fresh install creates the store
  /// and the index together. Both happen in the `versionchange` transaction,
  /// which makes the upgrade all or nothing: a failure aborts it, this open
  /// fails, and the database stays at version 1 with every record intact for
  /// the next attempt. The composition root then runs this session on
  /// `MemoryFeedbackSink`, so a failed migration costs durability for one
  /// session rather than the boot.
  ///
  /// ## Why a timeout, on an operation that looks instant
  ///
  /// An open that needs a version upgrade waits for every other connection to
  /// the same database to close, and fires `blocked` rather than failing. A
  /// second tab left open on the previous schema version therefore stalls this
  /// one **indefinitely** — no error, no progress. Version 2 is the first
  /// upgrade this database has taken, so it is the first time a connection on
  /// an older version can exist at all.
  ///
  /// `blocked` is surfaced as an error immediately, so the ordinary case does
  /// not wait out the timeout; the timeout is the backstop for everything else
  /// a browser can do instead of answering.
  ///
  /// In practice that version-1 tab does not reach it: every build that ever
  /// wrote version 1 carries the `versionchange` handler below, so the older
  /// connection steps aside and the upgrade simply proceeds. What `blocked`
  /// covers is a connection that will not yield, from whatever holds one. The
  /// tab holding it keeps its queue; this tab degrades to `MemoryFeedbackSink`
  /// for the session, like any other open that fails.
  static Future<IndexedDbFeedbackSink> open({
    String databaseName = defaultDatabaseName,
    Duration openTimeout = defaultOpenTimeout,
    @visibleForTesting int schemaVersion = _schemaVersion,
  }) async {
    final request = web.window.indexedDB.open(databaseName, schemaVersion);
    request.onupgradeneeded = ((web.IDBVersionChangeEvent event) {
      // Runs for a fresh install (from 0), for the migration (from 1), and
      // for a test's upgrade past the current version, where the index is
      // already there. Awaits nothing: the `versionchange` transaction dies
      // across a non-IndexedDB await like any other (class doc).
      final database = request.result! as web.IDBDatabase;
      if (!database.objectStoreNames.contains(_storeName)) {
        database.createObjectStore(_storeName);
      }
      final store = request.transaction!.objectStore(_storeName);
      if (!store.indexNames.contains(_ageIndexName)) {
        store.createIndex(_ageIndexName, _ageField.toJS);
      }
      if (event.oldVersion == 1) _migrateFromV1(store);
    }).toJS;

    final opening = _awaitOpen(request);
    final web.IDBDatabase database;
    try {
      database = (await opening.timeout(openTimeout))! as web.IDBDatabase;
    } on Object {
      // A late arrival still holds a connection, and that connection would
      // block the next tab's upgrade — the very failure this timeout exists
      // to bound. Nothing can await it by then, so close it on arrival.
      //
      // This covers the *timeout* only: the open itself is still pending here,
      // so it completes normally and this `then` runs. A `blocked` open has
      // already errored `opening`, and is closed in `_awaitOpen` instead.
      unawaited(
        opening
            .then((late) => (late as web.IDBDatabase?)?.close())
            .catchError((_) {}),
      );
      rethrow;
    }

    // Yield to another tab that wants to upgrade the schema, rather than
    // blocking it for as long as this tab stays open. The cost is that this
    // sink's later operations fail on a closed connection, which the service
    // reports as a persistence failure — worse for this tab, and far better
    // than the alternative, which is hanging every other one.
    database.onversionchange = ((web.Event _) => database.close()).toJS;

    return IndexedDbFeedbackSink._(database, databaseName);
  }

  /// Closes the connection when the root container tears down.
  ///
  /// [Disposable] rather than a bespoke `close()`, so the root module disposes
  /// this with the same idiom it already uses for `ConnectivityService` and
  /// does not grow a second one.
  @override
  Future<void> onDispose() async => _database.close();

  @override
  Future<void> persist(QueuedFeedbackReport record) async {
    final key = _addressOf(record);
    await _transaction((store) async {
      // A create (#379), decided inside the transaction that writes, so no
      // other tab's write can land between the check and the put (#381).
      //
      // A record [pending] would emit under this key is the same submission
      // — the key is its idempotency token — so the first stays, as the
      // backend keeps the first report a repeated `clientRequestId` names.
      // Anything else under the key — a value that will not decode, or a
      // record filed under another key — is not a stored record. [pending]
      // would reap it, taking with it the report this call promised to
      // store, so the put replaces it.
      //
      // One read answers both questions. A get of a key that is not stored
      // comes back empty and reads no payload, so a new key, which is every
      // persist the app makes today, costs nothing more than a key lookup.
      final stored = await _awaitRequest(store.get(key.toJS));
      if (stored != null) {
        debugPayloadReads++;
        if (_decode(_jsonOf(stored))?.storageKey == key) return;
      }
      await _awaitRequest(store.put(_storedRecord(record), key.toJS));
      // Only a create grows the store. A put over an unreadable value
      // replaced it, so the cap has nothing to do.
      if (stored == null) await _enforceCap(store, justPersisted: key);
    });
  }

  @override
  Future<void> update(QueuedFeedbackReport record) async {
    final key = _addressOf(record);
    await _transaction((store) async {
      // Presence, and nothing else (#376). Checked inside the transaction that
      // performs the write, which is what makes "still stored" mean it at the
      // instant of writing rather than a moment before.
      final existing = await _awaitRequest(store.getKey(key.toJS));
      if (existing == null) return;
      await _awaitRequest(store.put(_storedRecord(record), key.toJS));
      // No cap enforcement, deliberately (#376): an update cannot grow the
      // queue, so there is nothing for eviction to do.
    });
  }

  @override
  Future<List<QueuedFeedbackReport>> pending() {
    return _transaction((store) async {
      final entries = await _entriesIn(store);
      if (entries == null) return const <QueuedFeedbackReport>[];

      var kept = <(String, QueuedFeedbackReport)>[];
      for (final entry in entries) {
        final decoded = _decode(entry.value);
        final key = entry.key;
        // Every reject case, and the order matters. The address has to be
        // usable text in its own right *before* it is compared: IndexedDB
        // takes numbers, dates and arrays as keys, and such a key reads as
        // null here — which would compare equal to the null `storageKey` of a
        // record carrying no `clientRequestId`, and the pair would then be
        // kept as drainable under an address that does not exist. An empty
        // key fails for the same reason `persist` rejects one.
        if (key == null ||
            key.isEmpty ||
            decoded == null ||
            decoded.storageKey != key) {
          await _deleteQuietly(store, entry.rawKey);
          continue;
        }
        kept.add((key, decoded));
      }

      // Enforced here as well as on `persist`, for the install that arrives
      // carrying a pre-cap backlog: otherwise it would sit over the cap until
      // the user happened to submit again, and a stalled queue is exactly what
      // makes that unlikely. The records are already decoded, so it costs a
      // sort. Same rule as `_enforceCap`, minus the just-persisted exemption —
      // nothing was handed to this call.
      final excess = kept.length - QueuedFeedbackReport.maxQueuedReports;
      if (excess > 0) {
        final byAge = [...kept]..sort(_oldestFirst);
        final evicted = <String>{};
        for (final (key, _) in byAge.take(excess)) {
          await _deleteQuietly(store, key.toJS);
          evicted.add(key);
        }
        kept = [
          for (final entry in kept)
            if (!evicted.contains(entry.$1)) entry,
        ];
      }

      // Drain order: longest-waited first, so a drain the #97 throttle stops
      // partway has sent the records that have waited longest rather than an
      // arbitrary prefix. `getAllKeys` would otherwise hand them over in
      // cuid2-lexical order, which carries no meaning at all.
      //
      // Native reads this from the file's mtime; the fields say it directly,
      // and say it better — mtime is restamped by an `update` counting a
      // failed attempt, so it answers "last written" where the drain wants
      // "waited longest since its last attempt".
      kept.sort((a, b) {
        final byWait = _waitingSince(a.$2).compareTo(_waitingSince(b.$2));
        return byWait != 0 ? byWait : a.$1.compareTo(b.$1);
      });
      return [for (final (_, record) in kept) record];
    });
  }

  @override
  Future<void> remove(String storageKey) async {
    await _transaction((store) async {
      await _awaitRequest(store.delete(storageKey.toJS));
    });
  }

  /// The keys currently stored, in IndexedDB's ascending key order.
  ///
  /// For tests that need to assert a record was *deleted* rather than merely
  /// filtered out of [pending] — the difference the #161 reap is about, and
  /// one the public surface cannot otherwise show.
  @visibleForTesting
  Future<List<String>> rawKeys() => _transaction((store) async {
    final entries = await _entriesIn(store);
    return [for (final entry in entries ?? const []) ?entry.key];
  });

  /// Holds the store at [QueuedFeedbackReport.maxQueuedReports], deleting
  /// oldest-first by [QueuedFeedbackReport.queuedAt] (#359), and reading no
  /// report to do it (#386).
  ///
  /// The order is the `byAge` index's: its primary keys come back by `ageMs`
  /// ascending, ties in ascending primary-key order, which is the age-then-key
  /// rule [pending]'s own cap applies to decoded records. `ageMs` is
  /// `queuedAt` and never anything derived from last-written time: [update]
  /// rewrites a record to count a failed attempt, so a write-time ordering
  /// would say "newest" about the record that has been queued longest. A
  /// record with no `queuedAt` carries `ageMs` 0 — it predates the field, so
  /// it genuinely is oldest — and so does a version-1 value that would not
  /// decode, which [pending] reaps on its next call anyway.
  ///
  /// The excess is the store's key count over the bound. A value missing from
  /// the index — one whose `ageMs` is absent or not a valid key, which this
  /// sink never writes — counts toward that total, so the bound still holds,
  /// but it is never a candidate. [pending]'s cap works from decoded records
  /// and covers it.
  ///
  /// The cost is two key listings once the bound is exceeded, and one under
  /// it, which is every persist on a queue that drains. Neither path clones a
  /// report. Before the index, the over-bound path read every payload to learn
  /// their ages: up to roughly 12.5 MB at the per-report protocol ceiling, on
  /// every submit to a full queue.
  ///
  /// **Nothing here may fail the caller.** [persist] has already put the
  /// record by the time this runs, so an escape would have `submit` report
  /// `FeedbackPersistenceException` — "could not be saved" — about a report
  /// that is safely stored. Native says the same at its own call site and
  /// gets it with a `try`; that is not enough inside a transaction, because a
  /// failed IndexedDB request aborts its transaction unless the error event is
  /// *canceled* — a Dart `catch` would leave the abort to roll the put back.
  /// So every request here goes through the quiet helpers, and a read this
  /// method cannot complete simply leaves the cap for the next persist. Being
  /// one record over the bound harms nothing.
  ///
  /// The same goes for the index itself. `store.index` *throws* for an index
  /// that does not exist rather than failing a request, so the cap checks for
  /// `byAge` first. A version-2 store without it is one this class never
  /// builds, because the upgrade creates it from every older version. If one
  /// turns up anyway, the cap steps aside, and [pending]'s cap, which works
  /// from decoded records, still bounds the store.
  ///
  /// Native additionally exempts a record whose age it cannot *determine*,
  /// excluding it from the candidates and from the overflow arithmetic alike,
  /// so that a file a backup process is holding open cannot make eviction
  /// delete readable reports to pay for it. That case cannot arise here and
  /// the branch is absent rather than forgotten: inside a transaction that
  /// succeeded, the whole index has been read, and a store fault fails the
  /// read instead and deletes nothing. A value outside the index is not a
  /// record whose age is unknown for now but one written wrongly, which is
  /// why it still counts.
  Future<void> _enforceCap(
    web.IDBObjectStore store, {
    required String justPersisted,
  }) async {
    final keys = await _keysIn(store);
    if (keys == null) return;

    final excess = keys.length - QueuedFeedbackReport.maxQueuedReports;
    if (excess <= 0) return;

    if (!store.indexNames.contains(_ageIndexName)) return;
    // Primary keys in eviction order, and no values with them.
    final byAge = await _awaitOptional(store.index(_ageIndexName).getAllKeys());
    if (byAge == null) return;

    var evicted = 0;
    for (final rawKey in (byAge as JSArray<JSAny?>).toDart) {
      if (evicted == excess) break;
      // Counts against the cap, but is never up for deletion: `persist`
      // returning has to mean the record is stored, and `submit` reports
      // `queued` on the strength of that.
      if (_asText(rawKey) == justPersisted) continue;
      await _deleteQuietly(store, rawKey);
      evicted++;
    }
  }

  /// The shared oldest-first order, with the key tie-break this sink can see.
  static int _oldestFirst(
    (String, QueuedFeedbackReport) a,
    (String, QueuedFeedbackReport) b,
  ) {
    final byAge = QueuedFeedbackReport.compareByAge(a.$2, b.$2);
    return byAge != 0 ? byAge : a.$1.compareTo(b.$1);
  }

  /// How long this record has been waiting for a send it has not had.
  ///
  /// `lastAttemptAt` once an attempt has failed, and the queue stamp before
  /// that. Both are absent on a record written before either field existed,
  /// which sorts oldest — the same degradation [QueuedFeedbackReport.ageKey]
  /// applies for eviction.
  static DateTime _waitingSince(QueuedFeedbackReport record) =>
      record.lastAttemptAt ?? record.ageKey;

  /// The address to file [record] under.
  ///
  /// Throws [ArgumentError] when it has none, matching `persist`'s contract
  /// and native's. *Has no address* and *address not present* are deliberately
  /// different outcomes (#376); only [update] has the second, and it is a
  /// no-op rather than an error.
  static String _addressOf(QueuedFeedbackReport record) {
    final key = record.storageKey;
    if (key == null || key.isEmpty) {
      throw ArgumentError.value(
        key,
        'record',
        'a feedback record must carry a storage key',
      );
    }
    return key;
  }

  /// Decodes a stored record's JSON, or null when there is nothing decodable
  /// there.
  ///
  /// Null means *corrupt*, not *unavailable*: the value has already been read
  /// out of the store by the time this runs, so the only ways to get here are
  /// a value with no JSON text in it — see [_jsonOf] — and text that will not
  /// parse. Both make the record permanently un-drainable, which is the only
  /// distinction the callers need.
  static QueuedFeedbackReport? _decode(String? value) {
    if (value == null) return null;
    try {
      return QueuedFeedbackReport.fromJson(
        jsonDecode(value) as Map<String, dynamic>,
      );
    } on Object {
      // Any decode fault — malformed JSON, the wrong shape, a field whose type
      // changed — makes this record permanently un-drainable, which is the
      // only distinction the caller needs.
      return null;
    }
  }

  /// The value this sink stores; see the class doc. Both properties, always.
  static JSObject _storedValue({required int ageMs, required String json}) =>
      JSObject()
        ..[_ageField] = ageMs.toJS
        ..[_jsonField] = json.toJS;

  /// [record] as this sink stores it, and the only way it writes one: the age
  /// and the JSON come from the same record in the same `put`, which is why
  /// the two cannot drift apart.
  static JSObject _storedRecord(QueuedFeedbackReport record) => _storedValue(
    ageMs: record.ageKey.millisecondsSinceEpoch,
    json: jsonEncode(record.toJson()),
  );

  /// The record's JSON out of a stored value: the `json` property when
  /// [value] is an object and that property is text, and null for anything
  /// else — a version-1 bare string, a number, an object without `json` or
  /// with the wrong type there.
  ///
  /// `ageMs` is deliberately not looked at. It never decides whether a record
  /// drains, only when the cap reaches it.
  static String? _jsonOf(JSAny? value) {
    if (!value.isA<JSObject>()) return null;
    return _asText((value! as JSObject)[_jsonField]);
  }

  /// The `ageMs` a version-1 value migrates with: its decoded
  /// [QueuedFeedbackReport.ageKey] in milliseconds, or 0 — the
  /// [QueuedFeedbackReport.epoch] — when it will not decode.
  static int _ageMsOfJson(String json) =>
      _decode(json)?.ageKey.millisecondsSinceEpoch ?? 0;

  /// Rewrites every version-1 value — the record's JSON, bare — in place as
  /// `{ageMs, json}`, inside the upgrade's `versionchange` transaction.
  ///
  /// `json` is the text unchanged and `ageMs` comes from its decoded
  /// `queuedAt`. Text that will not decode is wrapped with `ageMs` 0 all the
  /// same: the migration does not judge corruption, because [pending] already
  /// does and reaps it on its first call. A value that is not text is left as
  /// it is, for the same reason.
  ///
  /// Callback-driven rather than awaited: one cursor request fires `success`
  /// once per row, which [_awaitRequest]'s one-shot future cannot follow. And
  /// no error handler, deliberately: a failed read or rewrite goes uncanceled
  /// and aborts the `versionchange` transaction, which fails [open] and leaves
  /// version 1 standing, every record intact. A Dart exception thrown out of
  /// the handler aborts it the same way.
  static void _migrateFromV1(web.IDBObjectStore store) {
    final rows = store.openCursor();
    rows.onsuccess = ((web.Event _) {
      final cursor = rows.result as web.IDBCursorWithValue?;
      if (cursor == null) return; // Past the last row.
      final text = _asText(cursor.value);
      if (text != null) {
        cursor.update(_storedValue(ageMs: _ageMsOfJson(text), json: text));
      }
      cursor.continue_();
    }).toJS;
  }

  /// Runs [body] inside one `readwrite` transaction and waits for it to
  /// commit.
  ///
  /// The completion handlers are attached **before** [body] runs: the
  /// transaction commits as soon as its last request settles, so a handler
  /// attached afterwards could be attached to an event that has already fired
  /// and never resolve.
  Future<T> _transaction<T>(
    Future<T> Function(web.IDBObjectStore store) body,
  ) async {
    final transaction = _database.transaction(_storeName.toJS, 'readwrite');
    final committed = Completer<void>();
    transaction.oncomplete = ((web.Event _) {
      if (!committed.isCompleted) committed.complete();
    }).toJS;
    transaction.onerror = ((web.Event _) {
      if (!committed.isCompleted) {
        committed.completeError(
          StateError(
            'feedback store transaction failed: '
            '${transaction.error?.message ?? 'unknown error'}',
          ),
        );
      }
    }).toJS;
    transaction.onabort = ((web.Event _) {
      if (!committed.isCompleted) {
        committed.completeError(
          StateError(
            'feedback store transaction aborted: '
            '${transaction.error?.message ?? 'no reason given'}',
          ),
        );
      }
    }).toJS;

    final T result;
    try {
      result = await body(transaction.objectStore(_storeName));
    } on Object {
      // The transaction is left to abort on its own where it already has
      // (a failed request aborts it); calling abort on one that is already
      // finishing throws, and that throw would replace the informative error.
      try {
        transaction.abort();
      } on Object {
        // Intentionally ignored; see above.
      }
      // The abort this triggers completes `committed` with an error nobody is
      // left to await, and an unawaited error on a completer is an unhandled
      // zone error — a second, louder failure on top of the one being
      // rethrown. The request's own exception is the informative one.
      committed.future.ignore();
      rethrow;
    }
    await committed.future;
    return result;
  }

  /// Everything in the store: the raw key, that key as text when it is text,
  /// and the record's JSON when the value carries it as text.
  ///
  /// Null when the store could not be read; the caller leaves the store alone
  /// rather than acting on a partial picture.
  ///
  /// **Keys and values are typed defensively on purpose.** IndexedDB takes
  /// numbers, dates and arrays as keys as readily as strings, and any
  /// cloneable value — a string or a number as readily as an object — as a
  /// value. `as JSString` on such a key, or `as JSObject` on such a value,
  /// throws a `TypeError` out of the transaction body — which would abort the
  /// transaction and leave [pending] failing on every drain, with the reap
  /// that should have removed the offending record never running. A value
  /// this sink cannot read its JSON out of is therefore reported as null and
  /// reaped exactly like JSON that will not parse, which is what makes the
  /// class doc's "corrupt by elimination" true rather than nearly true.
  /// Nothing but this class writes to the store today; that is a reason for
  /// the case to be cheap, not a reason to let it be fatal.
  static Future<List<({JSAny? rawKey, String? key, String? value})>?>
  _entriesIn(web.IDBObjectStore store) async {
    final keys = await _keysIn(store);
    if (keys == null) return null;
    final values = await _valuesIn(store);
    if (values == null || values.length != keys.length) return null;

    return [
      for (var i = 0; i < keys.length; i++)
        (rawKey: keys[i].rawKey, key: keys[i].key, value: values[i]),
    ];
  }

  /// Every key in the store, raw and as text where it is text.
  ///
  /// Separate from [_valuesIn] so the cap can count without reading a single
  /// payload. Both yield ascending key order, so their results line up index
  /// for index — which is what lets a record be compared against the key it is
  /// filed under.
  static Future<List<({JSAny? rawKey, String? key})>?> _keysIn(
    web.IDBObjectStore store,
  ) async {
    final result = await _awaitOptional(store.getAllKeys());
    if (result == null) return null;
    return [
      for (final rawKey in (result as JSArray<JSAny?>).toDart)
        (rawKey: rawKey, key: _asText(rawKey)),
    ];
  }

  /// Counts every payload read. No cap path makes one; [persist]'s duplicate
  /// check makes exactly one, and only when the key is already present (a
  /// get of a key that is not stored returns nothing).
  ///
  /// That is a cost property with no behavioural signature — reading the
  /// payloads gives exactly the same answers — so nothing else would catch
  /// its loss. It has been lost once already, in a refactor that merged the
  /// key and value reads. Since #386 the cap reads no payload over the bound
  /// either, and the counter pins both paths.
  @visibleForTesting
  static int debugPayloadReads = 0;

  /// Every stored record's JSON, through [_jsonOf]: null for a value that does
  /// not carry it as text.
  static Future<List<String?>?> _valuesIn(web.IDBObjectStore store) async {
    debugPayloadReads++;
    final result = await _awaitOptional(store.getAll());
    if (result == null) return null;
    return [
      for (final value in (result as JSArray<JSAny?>).toDart) _jsonOf(value),
    ];
  }

  /// [value] as a Dart string, or null when it is not a JS string.
  static String? _asText(JSAny? value) =>
      value.isA<JSString>() ? (value! as JSString).toDart : null;

  /// Deletes [rawKey] without letting a failure reach the caller.
  ///
  /// Both callers are removing something already worthless — an un-drainable
  /// record, or one the cap has chosen — and letting either failure escape
  /// would abort the transaction: the drain would return nothing over a record
  /// it had already written off, and the cap would roll back the report it was
  /// making room for. `FileFeedbackSink._reap` is best-effort for the first of
  /// those reasons in as many words.
  static Future<void> _deleteQuietly(
    web.IDBObjectStore store,
    JSAny? rawKey,
  ) async {
    if (rawKey == null) return;
    await _awaitOptional(store.delete(rawKey));
  }

  /// Bridges one IndexedDB request to a [Future] that **never** rejects and
  /// never aborts the transaction, answering null on failure.
  ///
  /// Two cancellations are needed, and neither is what a Dart `try`/`catch`
  /// does. An IndexedDB request whose error event goes uncanceled aborts its
  /// transaction, so catching the rejected future would still lose every write
  /// the transaction had made — `preventDefault` is what stops the abort. But
  /// the event *also* bubbles from the request to the transaction, where
  /// [_transaction]'s own `onerror` would fail the operation anyway: the
  /// transaction would commit and the caller would still be told it had not.
  /// `stopPropagation` is what keeps the failure local to the request.
  ///
  /// Both measured rather than assumed, and the pair matters: with only
  /// `preventDefault`, a probe shows the transaction committing while
  /// `transaction.onerror` still fires.
  static Future<JSAny?> _awaitOptional(web.IDBRequest request) {
    final completer = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) {
      if (!completer.isCompleted) completer.complete(request.result);
    }).toJS;
    request.onerror = ((web.Event event) {
      event
        ..preventDefault()
        ..stopPropagation();
      if (!completer.isCompleted) completer.complete(null);
    }).toJS;
    return completer.future;
  }

  /// Bridges an **open** request to a [Future], treating `blocked` as a
  /// failure.
  ///
  /// Separate from [_awaitRequest] because `blocked` exists only on an open:
  /// it means another connection is holding the old version, and the request
  /// stays pending until that connection closes. Reporting it is what turns an
  /// indefinite stall into an answer the caller can degrade on.
  static Future<JSAny?> _awaitOpen(web.IDBOpenDBRequest request) {
    final completer = Completer<JSAny?>();
    void fail(String reason) {
      if (!completer.isCompleted) completer.completeError(StateError(reason));
    }

    request.onsuccess = ((web.Event _) {
      final database = request.result as web.IDBDatabase?;
      if (completer.isCompleted) {
        // `blocked` has already answered for this open, so nothing is waiting
        // on the connection that just arrived — and an unreferenced open
        // connection holds exactly the lock that made the open block. Closing
        // it here is what keeps this path from causing the failure it reports.
        database?.close();
        return;
      }
      completer.complete(database);
    }).toJS;
    request.onerror = ((web.Event _) {
      fail(
        'feedback store could not be opened: '
        '${request.error?.message ?? 'unknown error'}',
      );
    }).toJS;
    request.onblocked = ((web.Event _) {
      fail(
        'feedback store upgrade is blocked by another tab holding an '
        'older version of this database open',
      );
    }).toJS;
    return completer.future;
  }

  /// Bridges one IndexedDB request to a [Future].
  ///
  /// Awaiting this keeps the owning transaction alive; awaiting anything else
  /// inside one does not. See the class doc.
  static Future<JSAny?> _awaitRequest(web.IDBRequest request) {
    final completer = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) {
      completer.complete(request.result);
    }).toJS;
    request.onerror = ((web.Event _) {
      completer.completeError(
        StateError(
          'feedback store request failed: '
          '${request.error?.message ?? 'unknown error'}',
        ),
      );
    }).toJS;
    return completer.future;
  }
}
