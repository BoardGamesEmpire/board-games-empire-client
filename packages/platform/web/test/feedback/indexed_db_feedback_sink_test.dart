@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';
import 'package:web/web.dart' as web;
import 'package:web_platform/web_storage_composition.dart';

/// Contract pinned for the durable web sink (#292): the same observable
/// contract as `FileFeedbackSink`, over IndexedDB instead of a directory.
///
/// Browser-only, and it has to be: this exercises a real IndexedDB, which is
/// the whole point — a fake would assert the sink against the author's model
/// of the store rather than the store.
void main() {
  var counter = 0;

  /// A database name no other test in this run shares, registered for deletion
  /// when the test ends.
  ///
  /// Browser suites share one origin, so a fixed name would let one test's
  /// records reach another's — and the cap tests would be the ones to notice,
  /// confusingly. Unique names solve that and create a second problem: closing
  /// a connection leaves the database behind, so a run would deposit twenty of
  /// them in the origin and every later run would add twenty more, pressing on
  /// the quota the cap tests are the most sensitive to. Deleting is the other
  /// half of the isolation.
  String freshName() {
    final name =
        'bge_feedback_test_${DateTime.now().microsecondsSinceEpoch}_${counter++}';
    addTearDown(() async {
      final request = web.window.indexedDB.deleteDatabase(name);
      final deleted = Completer<void>();
      request.onsuccess = ((web.Event _) {
        if (!deleted.isCompleted) deleted.complete();
      }).toJS;
      request.onerror = ((web.Event _) {
        if (!deleted.isCompleted) deleted.complete();
      }).toJS;
      // A deletion blocked by a connection this test failed to close should
      // not hang the suite; the name is unique, so leaking one is survivable.
      request.onblocked = ((web.Event _) {
        if (!deleted.isCompleted) deleted.complete();
      }).toJS;
      await deleted.future.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    });
    return name;
  }

  QueuedFeedbackReport record(
    String? key, {
    String? serverId,
    DateTime? queuedAt,
    String message = 'pending',
    int retryCount = 0,
  }) => QueuedFeedbackReport(
    report: FeedbackReport(
      category: FeedbackCategory.bug,
      severity: FeedbackSeverity.low,
      message: message,
      clientRequestId: key,
    ),
    serverId: serverId,
    queuedAt: queuedAt,
    retryCount: retryCount,
  );

  /// Opens [databaseName] at whatever version it already has, with none of
  /// the sink's handlers on it.
  ///
  /// No version, so it joins the schema the sink built rather than asking for
  /// one: every caller opens the sink first, and a fixed version here would
  /// either downgrade-fail or upgrade past the sink.
  Future<web.IDBDatabase> openExisting(String databaseName) {
    final open = web.window.indexedDB.open(databaseName);
    final completer = Completer<web.IDBDatabase>();
    open.onsuccess = (web.Event _) {
      completer.complete(open.result! as web.IDBDatabase);
    }.toJS;
    open.onerror = (web.Event _) {
      completer.completeError(StateError('open failed'));
    }.toJS;
    return completer.future;
  }

  /// Writes straight to the store, bypassing [FeedbackSink.persist], under a
  /// key that need not be text at all.
  ///
  /// The reap cases need values `persist` would never produce — undecodable
  /// text, a record filed under the wrong key — so they cannot be set up
  /// through the sink's own front door.
  Future<void> writeRawKeyed(
    String databaseName,
    JSAny key,
    JSAny value,
  ) async {
    final db = await openExisting(databaseName);
    final tx = db.transaction('records'.toJS, 'readwrite');
    final done = Completer<void>();
    tx.oncomplete = ((web.Event _) => done.complete()).toJS;
    tx.onerror = ((web.Event _) => done.completeError(StateError('tx'))).toJS;
    tx.objectStore('records').put(value, key);
    await done.future;
    db.close();
  }

  /// [writeRawKeyed] under a text key, the only kind the sink writes.
  Future<void> writeRawValue(String databaseName, String key, JSAny value) =>
      writeRawKeyed(databaseName, key.toJS, value);

  /// A version-2 stored value carrying only the properties given, so a test
  /// can leave one out as well as get one wrong.
  JSObject storedValue({JSAny? ageMs, JSAny? json}) {
    final value = JSObject();
    if (ageMs != null) value['ageMs'] = ageMs;
    if (json != null) value['json'] = json;
    return value;
  }

  /// The version-2 value the sink stores for [record]: its age in
  /// milliseconds, and its JSON exactly as version 1 stored it.
  JSObject storedRecord(QueuedFeedbackReport record) => storedValue(
    ageMs: record.ageKey.millisecondsSinceEpoch.toJS,
    json: jsonEncode(record.toJson()).toJS,
  );

  /// Writes a version-2 value built by [storedValue].
  Future<void> writeRawRecord(
    String databaseName,
    String key, {
    JSAny? ageMs,
    JSAny? json,
  }) => writeRawValue(databaseName, key, storedValue(ageMs: ageMs, json: json));

  /// Writes a version-1 value — the record's JSON as bare text — into a
  /// version-2 store. Only tests about that shape should reach for this.
  Future<void> writeRaw(String databaseName, String key, String value) =>
      writeRawValue(databaseName, key, value.toJS);

  /// The stored value under [key], read straight from the store and
  /// converted to Dart: a `Map` for a version-2 value, a `String` for a
  /// version-1 one.
  Future<Object?> readRawValue(String databaseName, String key) async {
    final db = await openExisting(databaseName);
    final request = db
        .transaction('records'.toJS, 'readonly')
        .objectStore('records')
        .get(key.toJS);
    final read = Completer<JSAny?>();
    request.onsuccess = ((web.Event _) => read.complete(request.result)).toJS;
    request.onerror = ((web.Event _) => read.completeError(
      StateError('read failed'),
    )).toJS;
    final value = await read.future;
    db.close();
    return value.dartify();
  }

  /// A connection this suite owns outright, with none of the sink's own
  /// handlers on it — in particular no `onversionchange` yield.
  ///
  /// At version 1 this builds exactly what the version-1 sink built: the
  /// store, and no index. [ageIndex] adds one shaped like the sink's
  /// `byAge`, for tests about how IndexedDB treats an index rather than how
  /// the sink does.
  Future<web.IDBDatabase> openRawConnection(
    String name,
    int version, {
    bool ageIndex = false,
  }) async {
    final request = web.window.indexedDB.open(name, version);
    final ready = Completer<web.IDBDatabase>();
    request.onupgradeneeded = ((web.Event _) {
      final db = request.result! as web.IDBDatabase;
      if (!db.objectStoreNames.contains('records')) {
        db.createObjectStore('records');
      }
      if (ageIndex) {
        request.transaction!
            .objectStore('records')
            .createIndex('byAge', 'ageMs'.toJS);
      }
    }).toJS;
    request.onsuccess = ((web.Event _) {
      if (!ready.isCompleted) {
        ready.complete(request.result! as web.IDBDatabase);
      }
    }).toJS;
    request.onerror = ((web.Event _) {
      if (!ready.isCompleted) ready.completeError(StateError('open failed'));
    }).toJS;
    return ready.future;
  }

  /// A version-1 database as that build left it, holding [values] — each a
  /// record's JSON as bare text — and still open on the returned connection.
  /// [nonText] adds values that version-1 build never wrote but IndexedDB
  /// would have held all the same.
  ///
  /// Left open so a test can decide what that connection does when the
  /// version-2 sink asks it to step aside.
  Future<web.IDBDatabase> openVersion1(
    String name,
    Map<String, String> values, {
    Map<String, JSAny> nonText = const {},
  }) async {
    final db = await openRawConnection(name, 1);
    final tx = db.transaction('records'.toJS, 'readwrite');
    final done = Completer<void>();
    tx.oncomplete = ((web.Event _) => done.complete()).toJS;
    tx.onerror = ((web.Event _) => done.completeError(StateError('tx'))).toJS;
    final store = tx.objectStore('records');
    for (final MapEntry(:key, :value) in values.entries) {
      store.put(value.toJS, key.toJS);
    }
    for (final MapEntry(:key, :value) in nonText.entries) {
      store.put(value, key.toJS);
    }
    await done.future;
    return db;
  }

  /// [record]'s JSON, as version 1 stored it and version 2 keeps it.
  String jsonText(QueuedFeedbackReport record) => jsonEncode(record.toJson());

  /// `k00`, `k01`, …: keys whose text order is their numeric order, so a test
  /// can say which one is lexically first.
  String paddedKey(int i) => 'k${i.toString().padLeft(2, '0')}';

  group('IndexedDbFeedbackSink', () {
    test('is a FeedbackSink', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);
      expect(sink, isA<FeedbackSink>());
    });

    test('survives a restart (#385)', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);
      expect(sink.survivesRestart, isTrue);
    });

    test('round-trips records with their serverId tag', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);

      await sink.persist(record('key-a', serverId: 'srv-1'));
      await sink.persist(record('key-b'));
      final pending = await sink.pending();

      expect(
        pending.map((r) => r.storageKey),
        unorderedEquals(['key-a', 'key-b']),
      );
      expect(
        pending.firstWhere((r) => r.storageKey == 'key-a').serverId,
        'srv-1',
      );
      expect(
        pending.firstWhere((r) => r.storageKey == 'key-b').serverId,
        isNull,
      );
    });

    test('a persisted report survives the connection closing and reopening — '
        'the reload case this sink exists for', () async {
      final name = freshName();
      final first = await IndexedDbFeedbackSink.open(databaseName: name);
      await first.persist(record('survivor', message: 'written before reload'));
      await first.onDispose();

      final second = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(second.onDispose);
      final pending = await second.pending();

      expect(pending, hasLength(1));
      expect(pending.single.report.message, 'written before reload');
    });

    test('persist rejects a record with no storage key', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);

      expect(() => sink.persist(record(null)), throwsArgumentError);
    });

    test('persist with an existing key keeps the first record — the first '
        'submission wins, as on the backend (#379)', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);

      await sink.persist(record('dup', message: 'first'));
      await sink.persist(record('dup', message: 'second'));
      final pending = await sink.pending();

      expect(pending, hasLength(1));
      expect(pending.single.report.message, 'first');
    });

    test('persist replaces an undecodable value under its key — keeping it '
        'would let pending reap a report persist said was stored '
        '(#379)', () async {
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      await writeRawRecord(name, 'key-a', ageMs: 0.toJS, json: 'not json'.toJS);

      await sink.persist(record('key-a', message: 'replacement'));
      final pending = await sink.pending();

      expect(pending, hasLength(1));
      expect(pending.single.report.message, 'replacement');
    });

    test("persist replaces a value under its key that holds another key's "
        'record — pending would reap it as un-addressable, so it is not a '
        'stored record (#379)', () async {
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      await writeRawValue(
        name,
        'key-a',
        storedRecord(record('other', message: 'misfiled')),
      );

      await sink.persist(record('key-a', message: 'replacement'));
      final pending = await sink.pending();

      expect(pending.map((r) => r.storageKey), ['key-a']);
      expect(pending.single.report.message, 'replacement');
    });

    test(
      'remove deletes by storage key, and is a no-op for an absent one',
      () async {
        final sink = await IndexedDbFeedbackSink.open(
          databaseName: freshName(),
        );
        addTearDown(sink.onDispose);

        await sink.persist(record('gone'));
        await sink.remove('gone');
        await sink.remove('never-existed');

        expect(await sink.pending(), isEmpty);
      },
    );
  });

  group('the reap: a record it will not emit is deleted, not skipped (#161)', () {
    test('a value that will not decode is reaped', () async {
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      await sink.persist(record('good'));
      await writeRawRecord(
        name,
        'corrupt',
        ageMs: 0.toJS,
        json: 'this is not json'.toJS,
      );

      expect((await sink.pending()).map((r) => r.storageKey), ['good']);
      // Reaped, not merely skipped: a second call still sees only the good one
      // AND the bad value is gone from the store.
      expect((await sink.pending()).map((r) => r.storageKey), ['good']);
      expect(await sink.rawKeys(), ['good']);
    });

    test('a value that is not an object at all is reaped, not left to wedge '
        'every future drain', () async {
      // IndexedDB takes numbers and strings as values as readily as objects.
      // Reading `json` off a number as though it were the stored object
      // throws out of the transaction body, and an abort there would
      // mean pending() fails forever over a record the reap should have
      // removed on its first pass.
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      await sink.persist(record('good'));
      await writeRawValue(name, 'a-number', 42.toJS);

      expect((await sink.pending()).map((r) => r.storageKey), ['good']);
      expect(await sink.rawKeys(), ['good']);
    });

    test(
      'a record whose decoded key disagrees with its address is reaped',
      () async {
        final name = freshName();
        final sink = await IndexedDbFeedbackSink.open(databaseName: name);
        addTearDown(sink.onDispose);
        await writeRawValue(
          name,
          'filed-under-this',
          storedRecord(record('but-claims-this')),
        );

        expect(await sink.pending(), isEmpty);
        expect(await sink.rawKeys(), isEmpty);
      },
    );

    test('a record carrying no storage key at all is reaped — how every '
        'pre-#161 record still presents', () async {
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      await writeRawValue(name, 'orphan', storedRecord(record(null)));

      expect(await sink.pending(), isEmpty);
      expect(await sink.rawKeys(), isEmpty);
    });

    test('a bare string value — the version-1 shape — is reaped', () async {
      // A well-formed record filed under its own key, so the shape is the
      // only thing wrong with it. The upgrade rewrites every version-1 value,
      // so bare text in a version-2 store is nothing this sink wrote.
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      await sink.persist(record('good'));
      await writeRaw(name, 'bare', jsonText(record('bare')));

      expect((await sink.pending()).map((r) => r.storageKey), ['good']);
      expect(await sink.rawKeys(), ['good']);
    });

    test('an object whose json is not a string is reaped', () async {
      // The record itself as a structured object, valid and filed under its
      // own key, so "not a string" is the only fault. This is the design #386
      // rejected — storing the record as an object — and a `json` that only
      // reads back as the record's text is a record this sink would drain.
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      await sink.persist(record('good'));
      final structured = record('structured', queuedAt: DateTime.utc(2026, 6));
      await writeRawRecord(
        name,
        'structured',
        ageMs: DateTime.utc(2026, 6).millisecondsSinceEpoch.toJS,
        // Through JSON text, so nested values are plain maps and lists too.
        json: (jsonDecode(jsonText(structured)) as Object).jsify(),
      );

      expect((await sink.pending()).map((r) => r.storageKey), ['good']);
      expect(await sink.rawKeys(), ['good']);
    });

    test('a record with good json and no ageMs is NOT reaped and still drains '
        '— ageMs only orders eviction', () async {
      // IndexedDB leaves this record out of the age index, so the persist cap
      // can never choose it, and pending's own cap still covers it. Neither is
      // a reason to destroy a report that decodes under its own key.
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      await writeRawRecord(
        name,
        'ageless',
        json: jsonText(record('ageless', message: 'still here')).toJS,
      );

      final pending = await sink.pending();

      expect(pending.map((r) => r.storageKey), ['ageless']);
      expect(pending.single.report.message, 'still here');
      expect(await sink.rawKeys(), ['ageless']);
    });

    test('a non-numeric ageMs is NOT reaped', () async {
      // The ISO stamp where the integer belongs. A string is a valid
      // IndexedDB key, so the index does hold this record — after every
      // number, since IndexedDB orders numbers before strings — and the cap
      // would reach it last. Ordering is all ageMs is for.
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      await writeRawRecord(
        name,
        'stamped',
        ageMs: '2026-06-01T00:00:00.000Z'.toJS,
        json: jsonText(record('stamped', queuedAt: DateTime.utc(2026, 6))).toJS,
      );

      expect((await sink.pending()).map((r) => r.storageKey), ['stamped']);
      expect(await sink.rawKeys(), ['stamped']);
    });

    test('a wrong numeric ageMs — one that disagrees with the json — is NOT '
        'reaped, and the json decides the record', () async {
      // Queued in 2026, aged as 1999: the cap would reach this record early,
      // which is all a wrong ageMs can cost. The record drains as its json
      // says it is.
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      await writeRawRecord(
        name,
        'misdated',
        ageMs: DateTime.utc(1999).millisecondsSinceEpoch.toJS,
        json: jsonText(record('misdated', queuedAt: DateTime.utc(2026, 6)))
            .toJS,
      );

      final pending = await sink.pending();

      expect(pending.map((r) => r.storageKey), ['misdated']);
      expect(pending.single.queuedAt, DateTime.utc(2026, 6));
      expect(await sink.rawKeys(), ['misdated']);
    });

    test('a store fault is skipped, not reaped — unreadability is never a '
        'reason to delete (#292 D6)', () async {
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      await sink.persist(record('survivor'));

      // A closed connection is the one store fault a test against a real
      // IndexedDB can actually stage: a transaction cannot be opened on it
      // at all. The faults this rule was written for — quota exhaustion, a
      // corrupt backing store — are unreachable from here, and this reaches
      // the same code, since every read in `pending` is inside the
      // transaction that now cannot start.
      await sink.onDispose();

      await expectLater(sink.pending(), throwsA(anything));

      final reopened = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(reopened.onDispose);
      expect(
        (await reopened.pending()).map((r) => r.storageKey),
        ['survivor'],
        reason: 'a fault is transient: the record is retried, not written off',
      );
    });
  });

  group('update: presence-only, and never the create path (#376)', () {
    test('rewrites a record that is stored', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);
      await sink.persist(record('key', message: 'before'));

      await sink.update(record('key', message: 'after', retryCount: 3));
      final pending = await sink.pending();

      expect(pending.single.report.message, 'after');
      expect(pending.single.retryCount, 3);
    });

    test('is a no-op when the key is absent — it must not resurrect a record '
        'the cap already dropped', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);

      await sink.update(record('never-stored'));

      expect(await sink.pending(), isEmpty);
      expect(await sink.rawKeys(), isEmpty);
    });

    test(
      'rejects a record with no storage key, exactly as persist does',
      () async {
        final sink = await IndexedDbFeedbackSink.open(
          databaseName: freshName(),
        );
        addTearDown(sink.onDispose);

        expect(() => sink.update(record(null)), throwsArgumentError);
      },
    );

    test(
      'does not enforce the cap — an update cannot grow the queue',
      () async {
        final sink = await IndexedDbFeedbackSink.open(
          databaseName: freshName(),
        );
        addTearDown(sink.onDispose);
        for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
          await sink.persist(
            record('k$i', queuedAt: DateTime.utc(2026, 6, 1 + i)),
          );
        }

        await sink.update(
          record('k0', queuedAt: DateTime.utc(2026, 6), retryCount: 1),
        );

        expect(
          await sink.rawKeys(),
          hasLength(QueuedFeedbackReport.maxQueuedReports),
          reason: 'a full sink stays full; nothing was evicted to make room',
        );
      },
    );

    test('does not move a record in the age order — a counted attempt must '
        'not make the oldest record look new', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        await sink.persist(
          record('k$i', queuedAt: DateTime.utc(2026, 6, 1 + i)),
        );
      }
      // k0 is the oldest. Count a failed attempt against it, carrying its
      // stamp forward the way the drain's copyWith does.
      await sink.update(
        record('k0', queuedAt: DateTime.utc(2026, 6), retryCount: 1),
      );

      await sink.persist(record('newcomer', queuedAt: DateTime.utc(2026, 9)));
      final keys = (await sink.rawKeys()).toSet();

      expect(keys, isNot(contains('k0')), reason: 'still the oldest');
      expect(keys, contains('newcomer'));
    });
  });

  group('the cap (#359)', () {
    test('evicts oldest-first by queuedAt once full', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        await sink.persist(
          record('k$i', queuedAt: DateTime.utc(2026, 6, 1 + i)),
        );
      }

      await sink.persist(record('newcomer', queuedAt: DateTime.utc(2026, 9)));
      final keys = (await sink.rawKeys()).toSet();

      expect(keys, hasLength(QueuedFeedbackReport.maxQueuedReports));
      expect(keys, isNot(contains('k0')));
      expect(keys, contains('k1'));
      expect(keys, contains('newcomer'));
    });

    test('never evicts the record it was just handed, even when the device '
        'clock stepped backwards', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        await sink.persist(record('k$i', queuedAt: DateTime.utc(2026, 6)));
      }

      await sink.persist(record('backdated', queuedAt: DateTime.utc(1999)));
      final keys = (await sink.rawKeys()).toSet();

      expect(keys, contains('backdated'));
      expect(keys, hasLength(QueuedFeedbackReport.maxQueuedReports));
    });

    test('a record with no queuedAt is treated as oldest — it predates the '
        'field, so it genuinely is', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);
      await sink.persist(record('legacy'));
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports - 1; i++) {
        await sink.persist(
          record('k$i', queuedAt: DateTime.utc(2026, 6, 1 + i)),
        );
      }

      await sink.persist(record('newcomer', queuedAt: DateTime.utc(2026, 9)));
      final keys = (await sink.rawKeys()).toSet();

      expect(keys, isNot(contains('legacy')));
      expect(keys, hasLength(QueuedFeedbackReport.maxQueuedReports));
    });

    test('eviction follows ageMs, then key, among equal ages', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);
      // One age for every record, persisted in DESCENDING key order: the
      // first one stored is the lexically last. A tie broken by arrival
      // would evict k50; the index breaks it by primary key.
      final keys = [
        for (var i = QueuedFeedbackReport.maxQueuedReports; i >= 0; i--)
          paddedKey(i),
      ];
      for (final key in keys) {
        await sink.persist(record(key, queuedAt: DateTime.utc(2026, 1, 1)));
      }
      final stored = (await sink.rawKeys()).toSet();

      expect(stored, hasLength(QueuedFeedbackReport.maxQueuedReports));
      expect(
        keys.toSet().difference(stored),
        {'k01'},
        reason:
            'k00 was the one just persisted, so k01 is the first of the rest',
      );
    });

    test('an undecodable value counts against the cap and sorts oldest — '
        'unlike native, its age is never in doubt', () async {
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      // ageMs 0 is what the upgrade gives an undecodable version-1 value, and
      // the cap orders by ageMs alone: it never reads the json to find out
      // that it will not decode.
      await writeRawRecord(
        name,
        'corrupt',
        ageMs: 0.toJS,
        json: 'not json at all'.toJS,
      );
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports - 1; i++) {
        await sink.persist(
          record('k$i', queuedAt: DateTime.utc(2026, 6, 1 + i)),
        );
      }

      await sink.persist(record('newcomer', queuedAt: DateTime.utc(2026, 9)));
      final keys = (await sink.rawKeys()).toSet();

      expect(keys, isNot(contains('corrupt')));
      expect(keys, hasLength(QueuedFeedbackReport.maxQueuedReports));
      expect(keys, contains('k0'), reason: 'no readable record paid for it');
    });

    test('a value missing from the age index counts toward the excess but is '
        'never evicted — the oldest indexed record pays instead', () async {
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      // Good json and no ageMs: drainable, and outside the index. Oldest of
      // all by its json, so only the index can be what passes it over.
      // Together with the ordinary records it puts the store exactly at the
      // bound, so the persist below makes one eviction if the excess counts
      // the store, and none if it counted only the index.
      await writeRawRecord(
        name,
        'ageless',
        json: jsonText(record('ageless', queuedAt: DateTime.utc(1999))).toJS,
      );
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports - 1; i++) {
        await sink.persist(
          record('k$i', queuedAt: DateTime.utc(2026, 6, 1 + i)),
        );
      }

      await sink.persist(record('newcomer', queuedAt: DateTime.utc(2026, 9)));
      final keys = (await sink.rawKeys()).toSet();

      expect(keys, hasLength(QueuedFeedbackReport.maxQueuedReports));
      expect(keys, contains('ageless'), reason: 'never a candidate');
      expect(keys, isNot(contains('k0')), reason: 'the oldest indexed record');
      expect(keys, contains('k1'), reason: 'and only that one');
      expect(keys, contains('newcomer'));
    });

    test('a store without the age index fails no persist — the cap steps '
        'aside, and pending still bounds the store', () async {
      // A version-2 store with no `byAge`, which this class never builds: the
      // upgrade creates the index from every older version. `store.index`
      // throws for a missing index rather than failing a request, and a throw
      // there would abort the persist's own put.
      final name = freshName();
      (await openRawConnection(name, 2)).close();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      // Already over the bound, written behind the sink's back.
      const over = QueuedFeedbackReport.maxQueuedReports + 1;
      for (var i = 0; i < over; i++) {
        await writeRawValue(
          name,
          'k$i',
          storedRecord(record('k$i', queuedAt: DateTime.utc(2026, 6, 1 + i))),
        );
      }

      await sink.persist(record('newcomer', queuedAt: DateTime.utc(2026, 9)));
      final keys = (await sink.rawKeys()).toSet();

      expect(keys, contains('newcomer'), reason: 'persist kept its promise');
      expect(keys, hasLength(over + 1), reason: 'the cap evicted nothing');

      final pending = await sink.pending();
      expect(pending, hasLength(QueuedFeedbackReport.maxQueuedReports));
      expect(pending.map((r) => r.storageKey), contains('newcomer'));
      expect(
        await sink.rawKeys(),
        hasLength(QueuedFeedbackReport.maxQueuedReports),
      );
    });

    test('persist keeping a readable record runs no cap pass — the store '
        'cannot have grown (#379)', () async {
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      // Over the bound, written behind the sink's back so no cap pass has
      // run yet; a cap pass here would take `k0`, the oldest.
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports + 1; i++) {
        await writeRawValue(
          name,
          'k$i',
          storedRecord(
            record(
              'k$i',
              message: 'first',
              queuedAt: DateTime.utc(2026, 6, 1 + i),
            ),
          ),
        );
      }
      const stored = QueuedFeedbackReport.maxQueuedReports + 1;

      await sink.persist(
        record('k5', message: 'second', queuedAt: DateTime.utc(2026, 9)),
      );
      // rawKeys, not pending: pending enforces the cap itself.
      final keys = (await sink.rawKeys()).toSet();

      expect(keys, hasLength(stored), reason: 'nothing was evicted');
      expect(keys, contains('k0'));
      final kept = (await sink.pending()).singleWhere(
        (r) => r.storageKey == 'k5',
      );
      expect(kept.report.message, 'first');
    });

    test('persist replacing an undecodable value runs no cap pass — the '
        'store cannot have grown (#379)', () async {
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      // Over the bound, written behind the sink's back so no cap pass has
      // run yet. At or under the bound a cap pass deletes nothing, and
      // "nothing was evicted" could not fail; here one would take `k0`, the
      // oldest.
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        await writeRawValue(
          name,
          'k$i',
          storedRecord(record('k$i', queuedAt: DateTime.utc(2026, 6, 1 + i))),
        );
      }
      await writeRawRecord(
        name,
        'broken',
        ageMs: 0.toJS,
        json: 'not json'.toJS,
      );
      const over = QueuedFeedbackReport.maxQueuedReports + 1;

      await sink.persist(
        record(
          'broken',
          message: 'replacement',
          queuedAt: DateTime.utc(2026, 9),
        ),
      );
      // rawKeys, not pending: pending enforces the cap itself.
      final keys = (await sink.rawKeys()).toSet();

      expect(keys, hasLength(over));
      expect(
        keys,
        contains('k0'),
        reason: 'the oldest, so a cap pass would have taken it',
      );
      // Only now, with the count pinned: the value was replaced, not kept.
      final pending = await sink.pending();
      expect(
        pending.firstWhere((r) => r.storageKey == 'broken').report.message,
        'replacement',
      );
    });
  });

  group('drain order', () {
    test(
      'longest-waited first, counting a failed attempt as a wait reset',
      () async {
        final sink = await IndexedDbFeedbackSink.open(
          databaseName: freshName(),
        );
        addTearDown(sink.onDispose);
        // Queued oldest, but attempted most recently: it has waited least.
        await sink.persist(
          QueuedFeedbackReport(
            report: FeedbackReport(
              category: FeedbackCategory.bug,
              severity: FeedbackSeverity.low,
              message: 'tried recently',
              clientRequestId: 'aaa-oldest-queued',
            ),
            queuedAt: DateTime.utc(2026),
            lastAttemptAt: DateTime.utc(2026, 9),
          ),
        );
        await sink.persist(
          record('zzz-newer-queued', queuedAt: DateTime.utc(2026, 6)),
        );

        final pending = await sink.pending();

        expect(pending.map((r) => r.storageKey), [
          'zzz-newer-queued',
          'aaa-oldest-queued',
        ], reason: 'not the cuid2-lexical order getAllKeys would have given');
      },
    );
  });

  group('opening', () {
    test('two current-build tabs never block each other: the older connection '
        'yields on versionchange', () async {
      final name = freshName();
      final holder = await IndexedDbFeedbackSink.open(databaseName: name);

      // The holder's own `onversionchange` closes it, so the upgrade proceeds
      // rather than blocking. This is why `blocked` needs a hand-rolled
      // connection to reach at all — and why it is worth pinning that the
      // ordinary two-tab case simply works.
      final upgraded = await IndexedDbFeedbackSink.open(
        databaseName: name,
        schemaVersion: 3,
        openTimeout: const Duration(seconds: 10),
      );
      addTearDown(upgraded.onDispose);

      expect(await upgraded.rawKeys(), isEmpty);
      await holder.onDispose();
    });

    test('an open blocked by a connection that does NOT yield fails instead '
        'of waiting forever — the case the timeout exists for', () async {
      final name = freshName();
      // A raw connection with no `onversionchange` handler: one that will not
      // step aside, whatever holds it. The upgrade below has nothing to do but
      // wait — IndexedDB fires `blocked` and stays pending rather than
      // failing.
      final holder = await openRawConnection(name, 1);
      addTearDown(() => holder.close());

      await expectLater(
        IndexedDbFeedbackSink.open(
          databaseName: name,
          schemaVersion: 3,
          openTimeout: const Duration(seconds: 30),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('blocked by another tab'),
          ),
        ),
      );
    });

    test('an open that does not answer in time fails rather than hanging the '
        'bootstrap', () async {
      await expectLater(
        IndexedDbFeedbackSink.open(
          databaseName: freshName(),
          openTimeout: Duration.zero,
        ),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('concurrency: one transaction per operation, and no lock', () {
    test('overlapping persists all land — the browser orders them, where the '
        'native sink needs a mutex', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);

      // Deliberately not awaited one at a time: this is the claim the design
      // rests on, and a sink that read-modify-wrote across a yield would drop
      // most of these.
      await Future.wait([
        for (var i = 0; i < 12; i++)
          sink.persist(record('c$i', queuedAt: DateTime.utc(2026, 6, 1 + i))),
      ]);

      expect(await sink.rawKeys(), hasLength(12));
    });

    test('overlapping persists against a full store keep the cap exact and '
        'lose none of the newcomers', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        await sink.persist(
          record('k$i', queuedAt: DateTime.utc(2026, 6, 1 + i)),
        );
      }

      await Future.wait([
        for (var i = 0; i < 5; i++)
          sink.persist(record('new$i', queuedAt: DateTime.utc(2026, 9, 1 + i))),
      ]);
      final keys = (await sink.rawKeys()).toSet();

      expect(keys, hasLength(QueuedFeedbackReport.maxQueuedReports));
      for (var i = 0; i < 5; i++) {
        expect(keys, contains('new$i'), reason: 'persist promised it is saved');
      }
    });
  });

  group('the cap is enforced on drain too', () {
    test(
      'a store that arrives over the bound is trimmed by pending(), not '
      'left waiting for a submit that a stalled queue makes unlikely',
      () async {
        final name = freshName();
        final sink = await IndexedDbFeedbackSink.open(databaseName: name);
        addTearDown(sink.onDispose);
        // Written behind the sink's back, the way a pre-cap backlog arrives.
        for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports + 5; i++) {
          await writeRawValue(
            name,
            'old$i',
            storedRecord(
              record('old$i', queuedAt: DateTime.utc(2026, 6, 1 + i)),
            ),
          );
        }

        final pending = await sink.pending();

        expect(pending, hasLength(QueuedFeedbackReport.maxQueuedReports));
        expect(
          await sink.rawKeys(),
          hasLength(QueuedFeedbackReport.maxQueuedReports),
        );
        expect(
          pending.map((r) => r.storageKey),
          isNot(contains('old0')),
          reason: 'the oldest went first',
        );
      },
    );
  });

  group('keys this sink cannot address are reaped, not trusted', () {
    test('a non-text key whose record also carries no clientRequestId is '
        'reaped — two nulls must not compare equal and pass as drainable', () async {
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      // A numeric key is a valid IndexedDB key, and reads as null text here.
      // The record under it has no clientRequestId, so its storageKey is null
      // too: compared directly, the two agree, and the record would be kept as
      // drainable under an address `remove` could never target.
      await writeRawKeyed(name, 7.toJS, storedRecord(record(null)));
      await sink.persist(record('good'));

      expect((await sink.pending()).map((r) => r.storageKey), ['good']);
      expect(await sink.rawKeys(), ['good']);
    });

    test('an empty key is reaped — persist rejects one, so nothing may be '
        'drained under it either', () async {
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      await writeRawValue(name, '', storedRecord(record('')));

      expect(await sink.pending(), isEmpty);
      expect(await sink.rawKeys(), isEmpty);
    });
  });

  group("the cap's fast path", () {
    test('a persist under the bound reads no payloads — one key listing and '
        'nothing else', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);
      await sink.persist(record('first'));

      final before = IndexedDbFeedbackSink.debugPayloadReads;
      await sink.persist(record('second'));

      expect(
        IndexedDbFeedbackSink.debugPayloadReads,
        before,
        reason:
            'a get of a new key returns nothing, so reads no payload, and '
            'under the cap there is one key listing and nothing else',
      );
    });

    test('a persist of a key already stored reads exactly one payload — '
        'the duplicate check, and only because the key was there', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);
      await sink.persist(record('first'));

      final before = IndexedDbFeedbackSink.debugPayloadReads;
      await sink.persist(record('first', message: 'again'));

      expect(IndexedDbFeedbackSink.debugPayloadReads, before + 1);
    });

    test('a persist that overflows the bound reads no payloads either — the '
        'index answers it', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        await sink.persist(
          record('k$i', queuedAt: DateTime.utc(2026, 6, 1 + i)),
        );
      }

      final before = IndexedDbFeedbackSink.debugPayloadReads;
      await sink.persist(record('overflow', queuedAt: DateTime.utc(2026, 9)));

      expect(
        IndexedDbFeedbackSink.debugPayloadReads,
        before,
        reason:
            'the age index hands over the candidates in eviction order, so '
            'no report is cloned to learn its age',
      );
      // Only now, with the count pinned — rawKeys reads payloads itself: the
      // cap did run, and took the oldest.
      final keys = (await sink.rawKeys()).toSet();
      expect(keys, hasLength(QueuedFeedbackReport.maxQueuedReports));
      expect(keys, isNot(contains('k0')));
    });
  });

  group('schema version 2 migration (#386)', () {
    // Each test builds the database as the version-1 build left it — the
    // store, no index, every value bare JSON text — and then opens the
    // current sink over it: the upgrade a returning dev install takes.

    test(
      'records written by version 1 survive the upgrade and drain',
      () async {
        final name = freshName();
        final first = record(
          'v1-a',
          message: 'first',
          queuedAt: DateTime.utc(2026, 6, 1),
        );
        final second = record(
          'v1-b',
          message: 'second',
          queuedAt: DateTime.utc(2026, 6, 2),
        );
        (await openVersion1(name, {
          'v1-a': jsonText(first),
          'v1-b': jsonText(second),
        })).close();

        final sink = await IndexedDbFeedbackSink.open(databaseName: name);
        addTearDown(sink.onDispose);

        // Rewritten in place rather than merely still readable: the json
        // exactly as version 1 stored it, the age taken from its queuedAt.
        for (final (key, stored) in [('v1-a', first), ('v1-b', second)]) {
          expect(await readRawValue(name, key), {
            'ageMs': stored.queuedAt!.millisecondsSinceEpoch,
            'json': jsonText(stored),
          });
        }
        final pending = await sink.pending();
        expect(
          {for (final r in pending) r.storageKey: r.report.message},
          {'v1-a': 'first', 'v1-b': 'second'},
        );
      },
    );

    test('the upgrade indexes version-1 records by age, so the cap evicts the '
        'oldest', () async {
      final name = freshName();
      // One short of the bound, so the persist below makes exactly one
      // eviction. `old` is the oldest by age but not by key — `k00` sorts
      // before it — so only an age order can choose it.
      (await openVersion1(name, {
        'old': jsonText(record('old', queuedAt: DateTime.utc(1999))),
        for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports - 1; i++)
          paddedKey(i): jsonText(
            record(paddedKey(i), queuedAt: DateTime.utc(2026, 6, 1 + i)),
          ),
      })).close();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);

      final before = IndexedDbFeedbackSink.debugPayloadReads;
      await sink.persist(record('newcomer', queuedAt: DateTime.utc(2026, 9)));

      expect(
        IndexedDbFeedbackSink.debugPayloadReads,
        before,
        reason: 'the index chose, so no version-1 record had to be decoded',
      );
      final keys = (await sink.rawKeys()).toSet();
      expect(keys, hasLength(QueuedFeedbackReport.maxQueuedReports));
      expect(keys, isNot(contains('old')));
      expect(
        keys,
        contains('k00'),
        reason: 'exactly one eviction: the oldest of the rest stays',
      );
      expect(keys, contains('newcomer'));
    });

    test('an undecodable version-1 value survives the upgrade and is reaped by '
        'pending', () async {
      final name = freshName();
      (await openVersion1(name, {'garbled': 'not json'})).close();

      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);

      // The upgrade does not judge corruption: it wraps the text with
      // ageMs 0 and leaves the verdict to pending, which already makes it.
      expect(await readRawValue(name, 'garbled'), {
        'ageMs': 0,
        'json': 'not json',
      });
      expect(await sink.pending(), isEmpty);
      expect(await sink.rawKeys(), isEmpty);
    });

    test('a version-1 value that is not text survives the upgrade untouched, '
        'and is reaped by pending', () async {
      // Version 1 never wrote one, but IndexedDB would have held it. The
      // migration leaves it alone rather than judging it; a rewrite that
      // assumed text would abort the upgrade, and fail the open, over it.
      final name = freshName();
      final kept = record('kept', message: 'text, so migrated');
      (await openVersion1(
        name,
        {'kept': jsonText(kept)},
        nonText: {'a-number': 42.toJS},
      )).close();

      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);

      expect(await readRawValue(name, 'a-number'), 42);
      final pending = await sink.pending();
      expect(pending.map((r) => r.storageKey), ['kept']);
      expect(pending.single.report.message, 'text, so migrated');
      expect(await sink.rawKeys(), ['kept']);
    });

    test('a version-1 record without queuedAt migrates with ageMs 0 and evicts '
        'first', () async {
      final name = freshName();
      final legacy = record('legacy');
      (await openVersion1(name, {
        'legacy': jsonText(legacy),
        for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports - 1; i++)
          paddedKey(i): jsonText(
            record(paddedKey(i), queuedAt: DateTime.utc(2026, 6, 1 + i)),
          ),
      })).close();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);

      expect(await readRawValue(name, 'legacy'), {
        'ageMs': 0,
        'json': jsonText(legacy),
      });

      await sink.persist(record('newcomer', queuedAt: DateTime.utc(2026, 9)));
      final keys = (await sink.rawKeys()).toSet();

      expect(keys, hasLength(QueuedFeedbackReport.maxQueuedReports));
      expect(keys, isNot(contains('legacy')));
      expect(keys, contains('k00'), reason: 'exactly one eviction');
    });

    test('a second connection on version 1 that steps aside on versionchange '
        'lets the upgrade through, and its records drain', () async {
      final name = freshName();
      final queued = record(
        'waiting',
        message: 'queued by the old build',
        queuedAt: DateTime.utc(2026, 6),
      );
      final holder = await openVersion1(name, {'waiting': jsonText(queued)});
      addTearDown(() => holder.close());
      // What the version-1 build's sink does on versionchange. The test never
      // closes the holder itself, so this handler is the only thing that can
      // let the upgrade through.
      var steppedAside = false;
      holder.onversionchange = ((web.Event _) {
        steppedAside = true;
        holder.close();
      }).toJS;

      final sink = await IndexedDbFeedbackSink.open(
        databaseName: name,
        openTimeout: const Duration(seconds: 10),
      );
      addTearDown(sink.onDispose);

      expect(steppedAside, isTrue);
      final pending = await sink.pending();
      expect(pending.map((r) => r.storageKey), ['waiting']);
      expect(pending.single.report.message, 'queued by the old build');
    });
  });

  group('the IndexedDB behaviour this sink is built on', () {
    // Characterization tests. The class doc calls the first two measured
    // rather than documented, and both were got wrong once by reasoning about
    // them; the age index's docs rest on the last two. All are pinned here
    // rather than left as prose.

    /// Puts [values] into a raw store carrying a `byAge`-shaped index, and
    /// reads back the index's primary keys and the store's own count.
    Future<({List<Object?> indexed, int stored})> throughAgeIndex(
      Map<String, JSObject> values,
    ) async {
      final database = await openRawConnection(freshName(), 1, ageIndex: true);
      addTearDown(() => database.close());
      final store = database
          .transaction('records'.toJS, 'readwrite')
          .objectStore('records');
      for (final MapEntry(:key, :value) in values.entries) {
        store.put(value, key.toJS);
      }
      Future<JSAny?> read(web.IDBRequest request) {
        final done = Completer<JSAny?>();
        request.onsuccess = ((web.Event _) => done.complete(
          request.result,
        )).toJS;
        request.onerror = ((web.Event _) => done.completeError(
          StateError('read failed'),
        )).toJS;
        return done.future;
      }

      final indexed = await read(store.index('byAge').getAllKeys());
      final stored = await read(store.count());
      return (
        indexed: [
          for (final key in (indexed! as JSArray<JSAny?>).toDart) key.dartify(),
        ],
        stored: (stored! as JSNumber).toDartInt,
      );
    }

    test('an index leaves out a record whose indexed property is missing or '
        'is not a valid key', () async {
      // Why `ageMs` is always written, and why a value outside `byAge` is
      // never a cap candidate.
      final result = await throughAgeIndex({
        'missing': storedValue(json: 'x'.toJS),
        'boolean': storedValue(ageMs: true.toJS, json: 'x'.toJS),
        'number': storedValue(ageMs: 5.toJS, json: 'x'.toJS),
      });

      expect(result.stored, 3, reason: 'the store holds all three');
      expect(result.indexed, ['number'], reason: 'the index holds one');
    });

    test('an index orders every number before any string, and breaks ties by '
        'primary key', () async {
      // The cap's whole eviction order, and why an ISO stamp in `ageMs` is
      // reached last rather than reaped.
      final result = await throughAgeIndex({
        'a-string': storedValue(
          ageMs: '2026-06-01T00:00:00.000Z'.toJS,
          json: 'x'.toJS,
        ),
        'd-big': storedValue(ageMs: 9999999999999.toJS, json: 'x'.toJS),
        'z-five': storedValue(ageMs: 5.toJS, json: 'x'.toJS),
        'y-five': storedValue(ageMs: 5.toJS, json: 'x'.toJS),
      });

      expect(result.indexed, ['y-five', 'z-five', 'd-big', 'a-string']);
    });

    test('a canceled request error needs stopPropagation as well as '
        'preventDefault: preventDefault alone still fires transaction.onerror', () async {
      final outcomes = <String, bool>{};
      for (final stopPropagation in [false, true]) {
        final database = await openRawConnection(freshName(), 1);
        addTearDown(() => database.close());
        final transaction = database.transaction('records'.toJS, 'readwrite');
        final store = transaction.objectStore('records');
        var transactionErrored = false;
        final settled = Completer<String>();
        transaction.oncomplete = ((web.Event _) {
          if (!settled.isCompleted) settled.complete('committed');
        }).toJS;
        transaction.onabort = ((web.Event _) {
          if (!settled.isCompleted) settled.complete('aborted');
        }).toJS;
        transaction.onerror = ((web.Event _) => transactionErrored = true).toJS;

        final seeded = Completer<void>();
        final put = store.put('one'.toJS, 'k1'.toJS);
        put.onsuccess = ((web.Event _) => seeded.complete()).toJS;
        await seeded.future;

        // add() on an existing key is a ConstraintError: a real request error,
        // without needing the store to misbehave.
        final failed = Completer<void>();
        final duplicate = store.add('two'.toJS, 'k1'.toJS);
        duplicate.onerror = ((web.Event event) {
          event.preventDefault();
          if (stopPropagation) event.stopPropagation();
          failed.complete();
        }).toJS;
        await failed.future;

        expect(await settled.future, 'committed');
        outcomes['stopPropagation=$stopPropagation'] = transactionErrored;
      }

      expect(
        outcomes['stopPropagation=false'],
        isTrue,
        reason: 'preventDefault stops the abort, not the bubbling',
      );
      expect(
        outcomes['stopPropagation=true'],
        isFalse,
        reason: 'which is why _awaitOptional does both',
      );
    });

    test('a transaction survives an await on its own request and dies across '
        'any other', () async {
      final database = await openRawConnection(freshName(), 1);
      addTearDown(() => database.close());
      final transaction = database.transaction('records'.toJS, 'readwrite');
      final store = transaction.objectStore('records');

      Future<void> put(String key) {
        final done = Completer<void>();
        final request = store.put('v'.toJS, key.toJS);
        request.onsuccess = ((web.Event _) => done.complete()).toJS;
        request.onerror = ((web.Event _) => done.completeError(
          StateError('inactive'),
        )).toJS;
        return done.future;
      }

      await put('a');
      await expectLater(put('b'), completes);

      await Future<void>.delayed(Duration.zero);
      // `put` on a finished transaction throws synchronously rather than
      // rejecting its request, so the call is wrapped to catch it either way.
      await expectLater(
        Future<void>(() => put('c')),
        throwsA(anything),
        reason: 'the transaction went inactive across a non-IDB await',
      );
    });
  });
}
