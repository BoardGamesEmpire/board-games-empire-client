@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

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

  /// Writes straight to the store, bypassing [FeedbackSink.persist].
  ///
  /// The reap cases need values `persist` would never produce — undecodable
  /// text, a record filed under the wrong key — so they cannot be set up
  /// through the sink's own front door.
  Future<void> writeRawValue(
    String databaseName,
    String key,
    JSAny value,
  ) async {
    final open = web.window.indexedDB.open(databaseName, 1);
    final completer = Completer<web.IDBDatabase>();
    open.onsuccess = (web.Event _) {
      completer.complete(open.result! as web.IDBDatabase);
    }.toJS;
    open.onerror = (web.Event _) {
      completer.completeError(StateError('open failed'));
    }.toJS;
    final db = await completer.future;

    final tx = db.transaction('records'.toJS, 'readwrite');
    final done = Completer<void>();
    tx.oncomplete = ((web.Event _) => done.complete()).toJS;
    tx.onerror = ((web.Event _) => done.completeError(StateError('tx'))).toJS;
    tx.objectStore('records').put(value, key.toJS);
    await done.future;
    db.close();
  }

  /// A connection this suite owns outright, with none of the sink's own
  /// handlers on it — in particular no `onversionchange` yield.
  Future<web.IDBDatabase> openRawConnection(String name, int version) async {
    final request = web.window.indexedDB.open(name, version);
    final ready = Completer<web.IDBDatabase>();
    request.onupgradeneeded = ((web.Event _) {
      final db = request.result! as web.IDBDatabase;
      if (!db.objectStoreNames.contains('records')) {
        db.createObjectStore('records');
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

  /// Writes under a key that need not be text at all.
  Future<void> writeRawKeyed(
    String databaseName,
    JSAny key,
    String value,
  ) async {
    final database = await openRawConnection(databaseName, 1);
    final transaction = database.transaction('records'.toJS, 'readwrite');
    final done = Completer<void>();
    transaction.oncomplete = ((web.Event _) => done.complete()).toJS;
    transaction.onerror = ((web.Event _) => done.completeError(
      StateError('tx'),
    )).toJS;
    transaction.objectStore('records').put(value.toJS, key);
    await done.future;
    database.close();
  }

  /// The common case: a stored record is JSON text.
  Future<void> writeRaw(String databaseName, String key, String value) =>
      writeRawValue(databaseName, key, value.toJS);

  group('IndexedDbFeedbackSink', () {
    test('is a FeedbackSink', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);
      expect(sink, isA<FeedbackSink>());
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

    test(
      'persist with an existing key replaces rather than duplicates',
      () async {
        final sink = await IndexedDbFeedbackSink.open(
          databaseName: freshName(),
        );
        addTearDown(sink.onDispose);

        await sink.persist(record('dup', message: 'first'));
        await sink.persist(record('dup', message: 'second'));
        final pending = await sink.pending();

        expect(pending, hasLength(1));
        expect(pending.single.report.message, 'second');
      },
    );

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
      await writeRaw(name, 'corrupt', 'this is not json');

      expect((await sink.pending()).map((r) => r.storageKey), ['good']);
      // Reaped, not merely skipped: a second call still sees only the good one
      // AND the bad value is gone from the store.
      expect((await sink.pending()).map((r) => r.storageKey), ['good']);
      expect(await sink.rawKeys(), ['good']);
    });

    test('a value that is not text at all is reaped, not left to wedge every '
        'future drain', () async {
      // IndexedDB takes numbers, objects and dates as values. Reading one as a
      // string throws out of the transaction body, and an abort there would
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
        await writeRaw(
          name,
          'filed-under-this',
          jsonEncode(record('but-claims-this').toJson()),
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
      await writeRaw(name, 'orphan', jsonEncode(record(null).toJson()));

      expect(await sink.pending(), isEmpty);
      expect(await sink.rawKeys(), isEmpty);
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

    test('an undecodable value counts against the cap and sorts oldest — '
        'unlike native, its age is never in doubt', () async {
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      await writeRaw(name, 'corrupt', 'not json at all');
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
        schemaVersion: 2,
        openTimeout: const Duration(seconds: 10),
      );
      addTearDown(upgraded.onDispose);

      expect(await upgraded.rawKeys(), isEmpty);
      await holder.onDispose();
    });

    test('an open blocked by a connection that does NOT yield fails instead '
        'of waiting forever — the case the timeout exists for', () async {
      final name = freshName();
      // A raw connection with no `onversionchange` handler: a tab running a
      // build from before that yield existed. It will not step aside, so the
      // upgrade below has nothing to do but wait — IndexedDB fires `blocked`
      // and stays pending rather than failing.
      final holder = await openRawConnection(name, 1);
      addTearDown(() => holder.close());

      await expectLater(
        IndexedDbFeedbackSink.open(
          databaseName: name,
          schemaVersion: 2,
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
          await writeRaw(
            name,
            'old$i',
            jsonEncode(
              record('old$i', queuedAt: DateTime.utc(2026, 6, 1 + i)).toJson(),
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
      await writeRawKeyed(name, 7.toJS, jsonEncode(record(null).toJson()));
      await sink.persist(record('good'));

      expect((await sink.pending()).map((r) => r.storageKey), ['good']);
      expect(await sink.rawKeys(), ['good']);
    });

    test('an empty key is reaped — persist rejects one, so nothing may be '
        'drained under it either', () async {
      final name = freshName();
      final sink = await IndexedDbFeedbackSink.open(databaseName: name);
      addTearDown(sink.onDispose);
      await writeRaw(name, '', jsonEncode(record('').toJson()));

      expect(await sink.pending(), isEmpty);
      expect(await sink.rawKeys(), isEmpty);
    });
  });

  group("the cap's fast path", () {
    test('a persist under the bound reads no payloads — only once the cap '
        'engages is the queue worth cloning', () async {
      final sink = await IndexedDbFeedbackSink.open(databaseName: freshName());
      addTearDown(sink.onDispose);
      await sink.persist(record('first'));

      final before = IndexedDbFeedbackSink.debugPayloadReads;
      await sink.persist(record('second'));

      expect(
        IndexedDbFeedbackSink.debugPayloadReads,
        before,
        reason: 'under the cap, one key listing and nothing else',
      );
    });

    test('a persist that overflows the bound does read them', () async {
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
        greaterThan(before),
        reason: 'ages have to come from somewhere once eviction is real',
      );
    });
  });

  group('the IndexedDB behaviour this sink is built on', () {
    // Characterization tests. The class doc calls these measured rather than
    // documented, and both were got wrong once by reasoning about them, so
    // they are pinned here rather than left as prose.

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
