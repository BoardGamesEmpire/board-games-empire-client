import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_platform/native_platform.dart';
import 'package:observability/observability.dart';

/// Contract pinned:
///
/// - **Only user-approved reports reach this sink** (the #34 privacy
///   contract is upheld by the approval gate upstream); one JSON file
///   per record, named `<storageKey>.json`.
/// - On-disk shape is the [QueuedFeedbackReport] envelope (#97): report
///   plus the `bgeServerId` it was approved for. The pre-#97
///   bare-[FeedbackReport] compatibility path is **gone** as of #161 —
///   such a file is now reaped like any other undecodable one.
/// - **Lazy directory resolution**: the injected `directoryProvider`
///   (production default: a `path_provider`-backed subdirectory) is not
///   invoked at construction, so registering the sink in the root
///   module puts no plugin call on the boot hot path.
/// - **Writes are atomic** (write a uniquely-named temp, rename onto
///   `.json`), so a reader never observes a partial record. Load-bearing
///   for the reap: without it a persist racing a pending would expose a
///   truncated file that the reap would destroy. The temp name is unique
///   per call so two writes of the same key cannot collide, and an
///   abandoned temp is reclaimed once too old to belong to a live write.
/// - **`update` rewrites only what is already stored** (#376): it never
///   creates, never runs the cap, and reports nothing when the key is
///   absent. The existence check and the write share one turn of the
///   serialization below, which is what a caller holding a stale snapshot
///   cannot do for itself. Like every write here it restamps the file, so
///   the record moves to the back of `pending`'s drain order — deliberate,
///   and the one place this sink and `MemoryFeedbackSink` differ. Eviction
///   order is untouched, keying on `queuedAt`.
/// - **`persist` creates** (#379): a repeated key keeps the first readable
///   record and replaces an unreadable, mismatched or vanished one, with no
///   cap pass on either.
/// - **Un-drainable records are reaped, not skipped** (#161): anything
///   `pending` declines to emit is deleted, because none of it has an
///   address `remove` could ever clear. One exception — a *filesystem*
///   fault is not corruption, so an unreadable file is skipped and
///   retried. Malformed bytes are corruption and are reaped, which is why
///   `pending` reads bytes and decodes in Dart rather than calling
///   `readAsString` (see the sink's doc).
/// - **Operations are serialized**: `persist`, `update`, `pending`, and
///   `remove` each act on a pathname after an `await`, so interleaving them
///   turns the reap and the remove into time-of-check/time-of-use races that
///   delete a record written after the read they were based on.
///
/// A consequence worth stating for anyone extending these tests: the
/// reports directory belongs entirely to the sink, so **any** file in it
/// that is not a decodable, correctly-addressed envelope is reaped by
/// `pending()`. A placeholder file written into it will not survive a
/// `pending()` call.
void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bge_feedback_sink');
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  FileFeedbackSink buildSink({Future<Directory> Function()? provider}) =>
      FileFeedbackSink(directoryProvider: provider ?? () async => tempDir);

  FeedbackReport report(String key, {String message = 'pending'}) =>
      FeedbackReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        message: message,
        clientRequestId: key,
      );

  QueuedFeedbackReport record(
    String key, {
    String? serverId,
    String message = 'pending',
    DateTime? queuedAt,
  }) => QueuedFeedbackReport(
    report: report(key, message: message),
    serverId: serverId,
    queuedAt: queuedAt,
  );

  /// An envelope exactly as the pre-#161 encoder wrote it: the idempotency
  /// token under the old `correlationKey` field name. The current model
  /// cannot produce this, so it is built by rewriting the key — which is
  /// the point, since json_serializable ignores unrecognised keys and this
  /// therefore decodes *successfully* with a null storage key rather than
  /// throwing.
  String legacyEnvelopeJson(String key, {String? serverId}) {
    final envelope = record(key, serverId: serverId).toJson();
    final reportJson = envelope['report']! as Map<String, dynamic>;
    reportJson.remove('clientRequestId');
    reportJson['correlationKey'] = key;
    return jsonEncode(envelope);
  }

  /// Writes a record straight to disk, bypassing [FileFeedbackSink.persist]:
  /// no cap pass runs and the sink's age cache knows nothing of it, so a
  /// directory can be set up over the bound, or with ages the sink must read.
  Future<void> writeRecord(String key, {DateTime? queuedAt}) async {
    await File('${tempDir.path}/$key.json').writeAsString(
      jsonEncode(
        QueuedFeedbackReport(report: report(key), queuedAt: queuedAt).toJson(),
      ),
    );
  }

  // Denies reads on [file], returning whether that actually took effect.
  //
  // `chmod` is the only way to manufacture a read fault against a real
  // file, and it is POSIX-only — hence `testOn: 'posix'` on every case that
  // uses this. native_platform ships to Windows desktop too, where an
  // unguarded Process.run throws before the sink is ever exercised.
  //
  // It is advisory against a privileged runner as well: root reads a 000
  // file regardless, which would leave the file an ordinary readable record
  // and fail these cases for a reason that has nothing to do with the sink.
  // Callers skip visibly rather than assert a precondition the environment
  // refused to set up.
  Future<bool> denyReads(File file) async {
    await Process.run('chmod', ['000', file.path]);
    addTearDown(() => Process.run('chmod', ['644', file.path]));
    try {
      await file.readAsBytes();
      return false;
    } on FileSystemException {
      return true;
    }
  }

  /// The record stored in `<key>.json`, read straight off disk — for a test
  /// that must not call [FileFeedbackSink.pending], which runs a cap pass of
  /// its own.
  QueuedFeedbackReport onDisk(String key) => QueuedFeedbackReport.fromJson(
    jsonDecode(File('${tempDir.path}/$key.json').readAsStringSync())
        as Map<String, dynamic>,
  );

  group('FileFeedbackSink', () {
    test('is a FeedbackSink', () {
      expect(buildSink(), isA<FeedbackSink>());
    });

    test('survives a restart (#385)', () {
      expect(buildSink().survivesRestart, isTrue);
    });

    test('does not touch the directory provider at construction — no '
        'plugin call on the boot path', () {
      FileFeedbackSink(
        directoryProvider: () =>
            throw StateError('provider must not run at construction'),
      );
    });

    test('persist writes one JSON envelope file per record, named by '
        'storage key', () async {
      final sink = buildSink();

      await sink.persist(record('key-a', serverId: 'srv-1'));

      final file = File('${tempDir.path}/key-a.json');
      expect(file.existsSync(), isTrue);
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(decoded['serverId'], 'srv-1');
      expect(
        (decoded['report']! as Map<String, dynamic>)['clientRequestId'],
        'key-a',
      );
    });

    test('persist leaves no temp file behind on success', () async {
      final sink = buildSink();

      await sink.persist(record('key-a'));

      final names = tempDir
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .toList();
      expect(names, ['key-a.json']);
    });

    test('persist cleans up its temp file when the rename fails — no '
        'partial write is left for a later read to trip over', () async {
      final sink = buildSink();
      // A directory occupying the target name makes `rename` fail. The
      // specific errno differs by platform; only that it throws matters.
      await Directory('${tempDir.path}/blocked.json').create();

      await expectLater(sink.persist(record('blocked')), throwsA(anything));

      // Assert on the suffix, not a guessed name: temps carry a
      // per-call sequence, so naming one exactly would pass vacuously.
      final leftovers = tempDir
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .where((name) => name.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    });

    test('two overlapping persists of one key both complete, and the first '
        'record stays (#379)', () async {
      final sink = buildSink();

      // A resubmission racing a send still in flight, both falling back to
      // the queue. A failure from either would have _queue report a
      // persistence failure for a report that is in fact safely queued. The
      // lock orders the two, and the second finds the first stored and
      // keeps it, so one file holds the first and no temp is left behind.
      await expectLater(
        Future.wait([
          sink.persist(record('key-a', message: 'first')),
          sink.persist(record('key-a', message: 'second')),
        ]),
        completes,
      );

      final pending = await sink.pending();
      expect(pending.map((r) => r.storageKey), ['key-a']);
      expect(pending.single.report.message, 'first');
      final names = tempDir
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .toList();
      expect(names, ['key-a.json']);
    });

    test(
      'persist with an existing key keeps the first readable record (#379)',
      () async {
        final sink = buildSink();
        await sink.persist(record('key-a', message: 'first'));

        await sink.persist(record('key-a', message: 'second'));

        final pending = await sink.pending();
        expect(pending, hasLength(1));
        expect(pending.single.report.message, 'first');
      },
    );

    test('persist replaces an undecodable file under its key — keeping it '
        'would let pending reap a report persist said was stored '
        '(#379)', () async {
      final sink = buildSink();
      await File('${tempDir.path}/key-a.json').writeAsString('not json');

      await sink.persist(record('key-a', message: 'replacement'));

      final pending = await sink.pending();
      expect(pending, hasLength(1));
      expect(pending.single.report.message, 'replacement');
    });

    test("persist replaces a file under its key that holds another key's "
        'record — pending would reap it as un-addressable, so it is not a '
        'stored record (#379)', () async {
      final sink = buildSink();
      await File('${tempDir.path}/key-a.json').writeAsString(
        jsonEncode(record('other', message: 'misfiled').toJson()),
      );

      await sink.persist(record('key-a', message: 'replacement'));

      final pending = await sink.pending();
      expect(pending.map((r) => r.storageKey), ['key-a']);
      expect(pending.single.report.message, 'replacement');
    });

    test('persist keeps an UNREADABLE file under its key rather than '
        'replacing it — a read fault is not corruption (#379)', () async {
      final sink = buildSink();
      await sink.persist(record('key-a', message: 'first'));
      final file = File('${tempDir.path}/key-a.json');
      if (!await denyReads(file)) {
        markTestSkipped(
          'this runner still reads a chmod 000 file (root?), so the read '
          'fault this case needs cannot be established',
        );
        return;
      }

      // A rename needs write access to the directory, not to the file it
      // lands on, so nothing but the sink's own check stands between this
      // call and replacing a record that may be perfectly valid.
      await sink.persist(record('key-a', message: 'second'));

      await Process.run('chmod', ['644', file.path]);
      expect(onDisk('key-a').report.message, 'first');
    }, testOn: 'posix');

    test('persist writes the record when the file under its key vanishes '
        'between the existence check and the read — gone is neither locked '
        'nor corrupt, and nothing is stored (#379)', () async {
      final sink = buildSink();
      final target = '${tempDir.path}/key-a.json';

      // Another process sharing the directory deletes the file after the
      // sink saw it exist — the lock orders nothing outside this instance.
      // Staged by handing the sink, for this one path, a file that answers
      // the check and then is gone; every other path is a real file.
      await IOOverrides.runWithIOOverrides(
        () => sink.persist(record('key-a', message: 'replacement')),
        _VanishingFileOverrides(target),
      );

      expect(File(target).existsSync(), isTrue);
      expect(onDisk('key-a').report.message, 'replacement');
    });

    test('pending returns every persisted envelope with its server '
        'tag', () async {
      final sink = buildSink();
      await sink.persist(record('key-a', serverId: 'srv-1'));
      await sink.persist(record('key-b'));

      final pending = await sink.pending();

      expect(pending, hasLength(2));
      final byKey = {for (final r in pending) r.storageKey: r};
      expect(byKey.keys, containsAll(<String>['key-a', 'key-b']));
      expect(byKey['key-a']!.serverId, 'srv-1');
      expect(byKey['key-b']!.serverId, isNull);
    });

    test('pending drains oldest-first by write time, not by cuid2-'
        'lexical filename — a throttle-stopped drain sends the oldest '
        'records', () async {
      final sink = buildSink();
      // Keys chosen so lexical order ('aaa' first) contradicts write
      // order; mtimes are set explicitly so the test is immune to
      // filesystem timestamp resolution.
      await sink.persist(record('zzz-oldest'));
      await sink.persist(record('aaa-newest'));
      await File('${tempDir.path}/zzz-oldest.json')
          .setLastModified(DateTime(2026, 1, 1));
      await File('${tempDir.path}/aaa-newest.json')
          .setLastModified(DateTime(2026, 1, 2));

      final pending = await sink.pending();

      expect(pending.map((r) => r.storageKey), ['zzz-oldest', 'aaa-newest']);
    });

    test('pending reaps a pre-#161 record whose token was written as '
        'correlationKey — it decodes with no storage key, so it is '
        'dropped rather than silently stranded on disk', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));
      final stale = File('${tempDir.path}/stale.json');
      await stale.writeAsString(legacyEnvelopeJson('stale'));

      final pending = await sink.pending();

      expect(pending.map((r) => r.storageKey), ['key-a']);
      expect(
        stale.existsSync(),
        isFalse,
        reason:
            'the #161 decision is drop, not skip — a skipped file '
            'would leak for the life of the install',
      );
    });

    test('pending reaps a decoded record with no storage key — it could '
        'never be removed after a send (poison record), so the rest of '
        'the queue still drains', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));
      // A valid envelope whose report simply carries no clientRequestId.
      const keyless = QueuedFeedbackReport(
        report: FeedbackReport(
          category: FeedbackCategory.bug,
          severity: FeedbackSeverity.low,
          message: 'no key',
        ),
      );
      final orphan = File('${tempDir.path}/orphan.json');
      await orphan.writeAsString(jsonEncode(keyless.toJson()));

      final pending = await sink.pending();

      expect(pending.map((r) => r.storageKey), ['key-a']);
      expect(orphan.existsSync(), isFalse);
    });

    test('pending reaps a record whose inner storage key disagrees with '
        'its file name — remove() targets <key>.json, not this file, so '
        'it would be un-removable', () async {
      final sink = buildSink();
      // File named mismatch.json but the envelope inside is keyed 'other'.
      final mismatch = File('${tempDir.path}/mismatch.json');
      await mismatch.writeAsString(jsonEncode(record('other').toJson()));

      expect(await sink.pending(), isEmpty);
      expect(mismatch.existsSync(), isFalse);
    });

    test('a reaped record with a traversal key deletes the file it was '
        'read from, never a path rebuilt from that key', () async {
      // The reports directory sits one level down so the traversal target
      // lands inside the temp dir: a naive `<reports>/../keep.json` would
      // resolve to `<tempDir>/keep.json`. It must also live *outside* the
      // reports directory — a file inside it would be listed by pending()
      // and reaped on its own merits, which would prove nothing about
      // traversal.
      final reports = Directory('${tempDir.path}/reports');
      await reports.create(recursive: true);
      final sink = buildSink(provider: () async => reports);
      final traversalTarget = File('${tempDir.path}/keep.json')
        ..writeAsStringSync('{}');
      // An envelope carrying a traversal key, in a legitimately-named
      // file. The key fails _isSafeKey, so the record is un-addressable
      // and reaped — by deleting `evil.json`, not `../keep.json`.
      final evil = File('${reports.path}/evil.json');
      await evil.writeAsString(jsonEncode(record('../keep').toJson()));

      expect(await sink.pending(), isEmpty);
      expect(evil.existsSync(), isFalse);
      expect(traversalTarget.existsSync(), isTrue);
    });

    test('pending reaps a corrupted or wrong-shaped file instead of '
        'failing the whole read', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));
      final corrupt = File('${tempDir.path}/corrupt.json');
      await corrupt.writeAsString('not json at all');
      // Valid JSON that is not an envelope. The pre-#97 bare-report
      // fallback that used to accept this shape was removed with #161.
      final wrongShape = File('${tempDir.path}/wrong_shape.json');
      await wrongShape.writeAsString('{"neither": true}');
      final bareReport = File('${tempDir.path}/bare.json');
      await bareReport.writeAsString(jsonEncode(report('bare').toJson()));

      final pending = await sink.pending();

      expect(pending.map((r) => r.storageKey), ['key-a']);
      expect(corrupt.existsSync(), isFalse);
      expect(wrongShape.existsSync(), isFalse);
      expect(bareReport.existsSync(), isFalse);
    });

    test('a persist racing a reap of the same key does not lose the new '
        'record — operations are serialized, so the reap cannot delete a '
        'file written after the read it was based on', () async {
      final sink = buildSink();
      // A file at key-a that cannot decode, so pending() will reap it.
      final path = File('${tempDir.path}/key-a.json');
      await path.writeAsString('not json at all');

      // Interleaved: without serialization, pending() can read the corrupt
      // bytes, persist() can rename a valid replacement onto the same
      // path, and the reap — which deletes by pathname — removes the new
      // report instead of the bytes that failed to decode.
      await Future.wait([
        sink.pending(),
        sink.persist(record('key-a', message: 'replacement')),
      ]);

      // Either order is acceptable; losing the record is not.
      final pending = await sink.pending();
      expect(pending.map((r) => r.storageKey), ['key-a']);
      expect(pending.single.report.message, 'replacement');
    });

    test('pending ignores a recent temp and leaves it alone — it may '
        'belong to an in-flight persist', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));
      final freshTemp = File('${tempDir.path}/key-b.json.0.tmp');
      await freshTemp.writeAsString(jsonEncode(record('key-b').toJson()));

      final pending = await sink.pending();

      expect(pending.map((r) => r.storageKey), ['key-a']);
      expect(freshTemp.existsSync(), isTrue);
    });

    test('pending reclaims a temp too old to belong to a live write — a '
        'hard kill mid-persist must not leak a file forever', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));
      final abandoned = File('${tempDir.path}/key-b.json.0.tmp');
      await abandoned.writeAsString(jsonEncode(record('key-b').toJson()));
      await abandoned.setLastModified(
        DateTime.now().subtract(const Duration(days: 2)),
      );

      final pending = await sink.pending();

      expect(pending.map((r) => r.storageKey), ['key-a']);
      expect(
        abandoned.existsSync(),
        isFalse,
        reason:
            'every abandoned temp has a distinct name, so never '
            'reclaiming them grows without bound',
      );
    });

    test('pending reaps a file whose bytes are not valid UTF-8 rather '
        'than skipping it — bad bytes never become good, so retrying '
        'forever would leak the file', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));
      // Read as bytes and decoded in Dart, so utf8.decode raises a
      // FormatException here. Under readAsString these bytes come back as
      // a FileSystemException instead — the same type as a real read
      // fault — and the file would be skipped and retried forever rather
      // than reaped. This case is what pins that distinction.
      final malformed = File('${tempDir.path}/malformed.json');
      await malformed.writeAsBytes([0xc3, 0x28, 0x80]);

      final pending = await sink.pending();

      expect(pending.map((r) => r.storageKey), ['key-a']);
      expect(malformed.existsSync(), isFalse);
    });

    test('pending is empty when nothing was ever persisted (directory '
        'absent)', () async {
      final sink = buildSink();
      final absent = buildSink(
        provider: () async => Directory('${tempDir.path}/never_created'),
      );

      expect(await absent.pending(), isEmpty);
      expect(await sink.pending(), isEmpty);
    });

    test('remove deletes the record file', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));
      await sink.persist(record('key-b'));

      await sink.remove('key-a');

      expect(File('${tempDir.path}/key-a.json').existsSync(), isFalse);
      expect((await sink.pending()).map((r) => r.storageKey), ['key-b']);
    });

    test('remove of an unknown key is a harmless no-op', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));

      await sink.remove('nope');

      expect(await sink.pending(), hasLength(1));
    });

    test('rejects a record without a storage key — files are named by '
        'it', () async {
      final sink = buildSink();
      const keyless = QueuedFeedbackReport(
        report: FeedbackReport(
          category: FeedbackCategory.bug,
          severity: FeedbackSeverity.low,
          message: 'pending',
        ),
      );

      await expectLater(sink.persist(keyless), throwsArgumentError);
    });

    test('persist rejects a storage key containing path segments — no '
        'traversal out of the reports directory', () async {
      final sink = buildSink();
      for (final key in <String>['../evil', 'a/b', r'a\b', '..']) {
        final invalid = QueuedFeedbackReport(report: report(key));
        await expectLater(
          sink.persist(invalid),
          throwsArgumentError,
          reason: 'key "$key" must be rejected',
        );
      }
    });

    test('remove rejects a storage key containing path segments — a '
        'crafted key cannot delete an arbitrary file', () async {
      final sink = buildSink();
      // A sibling file outside the "key" namespace that a traversal key
      // must not be able to reach. It survives because remove() rejects
      // each key before touching disk — NOT because its contents are
      // benign. Do not add a pending() call to this test: `{}` decodes
      // but is not an envelope, so pending() would reap it (#161) and the
      // assertion below would fail for reasons unrelated to remove().
      final bystander = File('${tempDir.path}/keep.json')
        ..writeAsStringSync('{}');

      for (final key in <String>['../keep', 'a/b', r'a\b', '..']) {
        await expectLater(
          sink.remove(key),
          throwsArgumentError,
          reason: 'key "$key" must be rejected',
        );
      }

      expect(bystander.existsSync(), isTrue);
    });
  });

  group('the cap (#359)', () {
    test('persist holds the directory at maxQueuedReports', () async {
      final sink = buildSink();
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports + 8; i++) {
        await sink.persist(
          record(
            'k$i',
            queuedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
          ),
        );
      }

      expect(
        await sink.pending(),
        hasLength(QueuedFeedbackReport.maxQueuedReports),
      );
    });

    test('evicts oldest-first by queuedAt, NOT by file mtime — a retry '
        'bump restamps mtime without making a record younger', () async {
      final sink = buildSink();
      // Fill to the cap with records that are already old.
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        await sink.persist(
          record(
            'old$i',
            queuedAt: DateTime.utc(2020, 1, 1).add(Duration(minutes: i)),
          ),
        );
      }
      // Rewrite the OLDEST one, exactly as counting a failed attempt does
      // (through update since #376). Its mtime is now the newest on disk;
      // its queuedAt is not.
      await sink.update(
        record(
          'old0',
          queuedAt: DateTime.utc(2020, 1, 1),
        ).copyWith(retryCount: 1),
      );
      // One more record tips the directory over the cap.
      await sink.persist(
        record('newcomer', queuedAt: DateTime.utc(2026, 9, 11)),
      );

      final keys = (await sink.pending()).map((r) => r.storageKey).toSet();

      expect(keys, hasLength(QueuedFeedbackReport.maxQueuedReports));
      // Keyed on mtime, 'old0' would have survived as the newest write.
      expect(keys, isNot(contains('old0')));
      expect(keys, contains('newcomer'));
    });

    test(
      'a record with no queuedAt evicts first — it predates the field',
      () async {
        final sink = buildSink();
        await sink.persist(record('legacy'));
        for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
          await sink.persist(
            record(
              'k$i',
              queuedAt: DateTime.utc(2024, 1, 1).add(Duration(minutes: i)),
            ),
          );
        }

        final keys = (await sink.pending()).map((r) => r.storageKey).toSet();

        expect(keys, isNot(contains('legacy')));
        expect(keys, hasLength(QueuedFeedbackReport.maxQueuedReports));
      },
    );

    // The two cases below start OVER the bound, written straight to disk so
    // no cap pass has run yet. At or under the bound a cap pass deletes
    // nothing, and "every file survived" could not fail. Here one would take
    // `k0`, the oldest, so a file count that holds proves no pass ran.
    // `pending` is not called: it enforces the cap itself.

    test('persist under a key it keeps runs no cap pass — the directory '
        'cannot have grown (#379)', () async {
      final sink = buildSink();
      const over = QueuedFeedbackReport.maxQueuedReports + 1;
      for (var i = 0; i < over; i++) {
        await writeRecord(
          'k$i',
          queuedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
        );
      }
      const newest = 'k${over - 1}';

      await sink.persist(
        record(newest, message: 'second', queuedAt: DateTime.utc(2026, 9)),
      );

      expect(tempDir.listSync().whereType<File>(), hasLength(over));
      expect(
        File('${tempDir.path}/k0.json').existsSync(),
        isTrue,
        reason: 'the oldest, so a cap pass would have taken it',
      );
      expect(onDisk(newest).report.message, 'pending', reason: 'kept');
    });

    test('persist replacing an undecodable file runs no cap pass — the '
        'directory cannot have grown (#379)', () async {
      final sink = buildSink();
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        await writeRecord(
          'k$i',
          queuedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
        );
      }
      await File('${tempDir.path}/broken.json').writeAsString('not json');
      const over = QueuedFeedbackReport.maxQueuedReports + 1;

      await sink.persist(
        record(
          'broken',
          message: 'replacement',
          queuedAt: DateTime.utc(2026, 9),
        ),
      );

      expect(tempDir.listSync().whereType<File>(), hasLength(over));
      expect(
        File('${tempDir.path}/k0.json').existsSync(),
        isTrue,
        reason: 'the oldest, so a cap pass would have taken it',
      );
      expect(onDisk('broken').report.message, 'replacement');
    });
  });

  group('the cap never destroys what it cannot read (#359 review)', () {
    test('an UNREADABLE record is never an eviction candidate — a read '
        'fault is not corruption, and this path deletes', () async {
      final sink = buildSink();
      // Oldest by queuedAt, so eviction would take it first of all.
      await writeRecord('locked', queuedAt: DateTime.utc(1999));
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        await writeRecord(
          'k$i',
          queuedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
        );
      }
      final locked = File('${tempDir.path}/locked.json');
      if (!await denyReads(locked)) {
        markTestSkipped(
          'this runner still reads a chmod 000 file (root?), so the read '
          'fault this case needs cannot be established',
        );
        return;
      }

      // Tips the directory over the cap, forcing an eviction pass.
      await sink.persist(
        record('newcomer', queuedAt: DateTime.utc(2026, 9, 11)),
      );

      expect(
        locked.existsSync(),
        isTrue,
        reason: 'a record that could not be read must survive the cap',
      );
    }, testOn: 'posix');

    test('an unreadable file is not PAID FOR by deleting extra readable '
        'records — excess counts what the sink can account for', () async {
      final sink = buildSink();
      await writeRecord('locked', queuedAt: DateTime.utc(1999));
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        await writeRecord(
          'k$i',
          queuedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
        );
      }
      final locked = File('${tempDir.path}/locked.json');
      if (!await denyReads(locked)) {
        markTestSkipped(
          'this runner still reads a chmod 000 file (root?), so the read '
          'fault this case needs cannot be established',
        );
        return;
      }

      // 52 files, 51 of them readable, cap 50 -> exactly ONE eviction.
      await sink.persist(
        record('newcomer', queuedAt: DateTime.utc(2026, 9, 11)),
      );

      expect(File('${tempDir.path}/k0.json').existsSync(), isFalse);
      expect(
        File('${tempDir.path}/k1.json').existsSync(),
        isTrue,
        reason: 'k1 would be the second eviction charged to the locked file',
      );
      expect(locked.existsSync(), isTrue);
      expect(File('${tempDir.path}/newcomer.json').existsSync(), isTrue);
    }, testOn: 'posix');

    test('a record this sink wrote keeps its cached age while unreadable, '
        'and is still evicted as the oldest (#378)', () async {
      final sink = buildSink();
      await sink.persist(record('cached', queuedAt: DateTime.utc(1999)));
      final cached = File('${tempDir.path}/cached.json');
      if (!await denyReads(cached)) {
        markTestSkipped(
          'this runner still reads a chmod 000 file (root?), so the read '
          'fault this case needs cannot be established',
        );
        return;
      }

      // 1 cached + 50 newer = 51 files, all 51 of known age (the cached one
      // from the age the sink stored when it wrote it) -> exactly ONE
      // eviction, and the oldest is `cached`.
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        await sink.persist(
          record(
            'k$i',
            queuedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
          ),
        );
      }

      expect(
        cached.existsSync(),
        isFalse,
        reason: 'its age is known from the cache, so it is not "unreadable"',
      );
      expect(File('${tempDir.path}/k0.json').existsSync(), isTrue);
    }, testOn: 'posix');

    test(
      'a cached-age record counts toward the cap and is evicted, so the '
      'uncached unreadable sibling costs no readable record (#378)',
      () async {
        final sink = buildSink();
        await sink.persist(record('cached', queuedAt: DateTime.utc(1999)));
        await writeRecord('locked', queuedAt: DateTime.utc(1998));
        for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports - 1; i++) {
          await writeRecord(
            'k$i',
            queuedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
          );
        }
        final cached = File('${tempDir.path}/cached.json');
        final locked = File('${tempDir.path}/locked.json');
        if (!await denyReads(cached) || !await denyReads(locked)) {
          markTestSkipped(
            'this runner still reads a chmod 000 file (root?), so the read '
            'fault this case needs cannot be established',
          );
          return;
        }

        // 52 files once `newcomer` lands: cached + locked + 49 k + newcomer.
        // 51 are of known age (all but `locked`), cap 50 -> exactly ONE
        // eviction, and it falls on `cached`, the oldest of those.
        await sink.persist(
          record('newcomer', queuedAt: DateTime.utc(2026, 9, 11)),
        );

        expect(cached.existsSync(), isFalse);
        expect(locked.existsSync(), isTrue);
        expect(
          File('${tempDir.path}/k0.json').existsSync(),
          isTrue,
          reason: 'k0 would be a second eviction charged to the locked file',
        );
        expect(File('${tempDir.path}/newcomer.json').existsSync(), isTrue);
      },
      testOn: 'posix',
    );

    test('the cache drops a name whose file another process deleted, so a '
        'new file under that name is aged from disk (#378)', () async {
      final sink = buildSink();
      await sink.persist(record('stale', queuedAt: DateTime.utc(1999)));
      // Another process removes the file behind the sink's back.
      File('${tempDir.path}/stale.json').deleteSync();
      // A cap pass at or under the bound still prunes the cache.
      await sink.persist(record('trigger', queuedAt: DateTime.utc(2026, 6, 1)));
      await writeRecord('stale', queuedAt: DateTime.utc(2030));
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports - 2; i++) {
        await writeRecord(
          'k$i',
          queuedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
        );
      }

      // 51 files once `newcomer` lands: stale + trigger + 48 k + newcomer
      // = 51, all readable, cap 50 -> exactly ONE eviction. With `stale`
      // aged from disk (2030) the oldest is k0; a surviving 1999 cache entry
      // would make it `stale` instead.
      await sink.persist(
        record('newcomer', queuedAt: DateTime.utc(2026, 9, 11)),
      );

      expect(File('${tempDir.path}/stale.json').existsSync(), isTrue);
      expect(File('${tempDir.path}/k0.json').existsSync(), isFalse);
    });

    test(
      'never evicts the record it was just handed, even backdated',
      () async {
        final sink = buildSink();
        for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
          await writeRecord('k$i', queuedAt: DateTime.utc(2026, 6, 1));
        }
        // A clock that stepped backwards makes the new record look oldest.
        await sink.persist(record('backdated', queuedAt: DateTime.utc(1999)));

        expect(File('${tempDir.path}/backdated.json').existsSync(), isTrue);
        expect(
          await sink.pending(),
          hasLength(QueuedFeedbackReport.maxQueuedReports),
        );
      },
    );

    test('pending enforces the cap too, so a pre-cap backlog does not '
        'persist forever on an upgraded install', () async {
      final sink = buildSink();
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports + 7; i++) {
        await writeRecord(
          'k$i',
          queuedAt: DateTime.utc(2025, 1, 1).add(Duration(minutes: i)),
        );
      }

      final pending = await sink.pending();

      expect(pending, hasLength(QueuedFeedbackReport.maxQueuedReports));
      // The oldest seven are gone from disk, not merely absent from the list.
      expect(File('${tempDir.path}/k0.json').existsSync(), isFalse);
      expect(File('${tempDir.path}/k6.json').existsSync(), isFalse);
      expect(File('${tempDir.path}/k7.json').existsSync(), isTrue);
    });
  });

  /// #376: the drain's write-backs address a record read from a snapshot
  /// taken before the drain started, so whether that record is still stored
  /// is a question only the sink can answer without a race.
  group('update (#376)', () {
    test('rewrites a stored record in place', () async {
      final sink = buildSink();
      await sink.persist(record('key-a', message: 'first'));

      await sink.update(record('key-a', message: 'second'));

      final pending = await sink.pending();
      expect(pending, hasLength(1));
      expect(pending.single.report.message, 'second');
      expect(
        Directory(tempDir.path).listSync().whereType<File>(),
        hasLength(1),
      );
    });

    test('restamps the file, so the record moves to the back of the drain '
        'order — deliberately, and unlike the memory sink', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));
      await sink.persist(record('key-b'));
      // Set explicitly so the test is immune to filesystem timestamp
      // resolution. Both are in the past, so the update's rename wins.
      await File('${tempDir.path}/key-a.json')
          .setLastModified(DateTime(2026, 1, 1));
      await File('${tempDir.path}/key-b.json')
          .setLastModified(DateTime(2026, 1, 2));

      await sink.update(record('key-a', message: 'counted'));

      // MemoryFeedbackSink leaves 'key-a' first; its own update test pins
      // that. Here the rewrite is what buys atomicity and the restamp comes
      // with it, so drain order reads "waited longest since its last
      // attempt" — which is what a drain stopped partway by a run-level
      // fault wants next time round. Eviction order is a separate question
      // and is untouched: it keys on `queuedAt`, as the cap group above
      // pins.
      expect((await sink.pending()).map((r) => r.storageKey), [
        'key-b',
        'key-a',
      ]);
    });

    test('is a no-op on a key with no file — it never creates one', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));

      await sink.update(record('evicted'));

      expect(File('${tempDir.path}/evicted.json').existsSync(), isFalse);
      expect((await sink.pending()).map((r) => r.storageKey), ['key-a']);
    });

    test('does not create the reports directory', () async {
      final missing = Directory('${tempDir.path}/not-yet');
      final sink = buildSink(provider: () async => missing);

      await sink.update(record('key-a'));

      expect(missing.existsSync(), isFalse);
    });

    test('rejects an un-addressable record, exactly as persist does', () async {
      final sink = buildSink();
      final keyless = QueuedFeedbackReport(
        report: const FeedbackReport(
          category: FeedbackCategory.bug,
          severity: FeedbackSeverity.low,
          message: 'pending',
        ),
      );

      await expectLater(sink.update(keyless), throwsArgumentError);
    });

    test('rejects a key that could traverse out of the reports '
        'directory', () async {
      final sink = buildSink();
      final escaping = QueuedFeedbackReport(report: report('../escape'));

      await expectLater(sink.update(escaping), throwsArgumentError);
    });

    test('leaves no temp file behind', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));

      await sink.update(record('key-a', message: 'second'));

      // `uri.pathSegments`, not a split on '/': `listSync` yields a
      // platform separator, and the desktop target includes Windows.
      final names = Directory(tempDir.path)
          .listSync()
          .map((e) => e.uri.pathSegments.last);
      expect(names, ['key-a.json']);
    });

    test('on a full directory, evicts nothing — an update cannot grow '
        'it', () async {
      final sink = buildSink();
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        await sink.persist(
          record('k$i', queuedAt: DateTime.utc(2026).add(Duration(minutes: i))),
        );
      }

      // The oldest record, which is what an eviction pass would take.
      await sink.update(
        record('k0', message: 'bumped', queuedAt: DateTime.utc(2026)),
      );

      expect(File('${tempDir.path}/k0.json').existsSync(), isTrue);
      expect(
        Directory(tempDir.path).listSync().whereType<File>(),
        hasLength(QueuedFeedbackReport.maxQueuedReports),
      );
    });

    test('a record removed first is not written back — the check and the '
        'write share one turn of the lock', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));

      // Issued without awaiting the remove, so both are queued on the
      // serialization in the order they were called.
      final removed = sink.remove('key-a');
      final updated = sink.update(record('key-a', message: 'second'));
      await Future.wait([removed, updated]);

      expect(File('${tempDir.path}/key-a.json').existsSync(), isFalse);
      expect(await sink.pending(), isEmpty);
    });
  });
}

/// Hands out [_VanishedFile] for [path] and a real file for every other
/// path, so the sink's temps and renames still touch the disk.
final class _VanishingFileOverrides extends IOOverrides {
  _VanishingFileOverrides(this.path);

  final String path;

  @override
  File createFile(String path) => path == this.path
      ? _VanishedFile(super.createFile(path))
      : super.createFile(path);
}

/// A file that was there when asked and is gone when read: what another
/// process deleting it between the two calls looks like from inside the sink.
class _VanishedFile implements File {
  _VanishedFile(this._real);

  final File _real;

  @override
  String get path => _real.path;

  @override
  Future<bool> exists() async => true;

  @override
  Future<Uint8List> readAsBytes() async => throw PathNotFoundException(
    path,
    const OSError('No such file or directory', 2),
    'Cannot open file',
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
