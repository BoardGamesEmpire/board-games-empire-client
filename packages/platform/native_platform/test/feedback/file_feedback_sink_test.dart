import 'dart:convert';
import 'dart:io';

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
///   per call so two persists of the same key cannot collide, and an
///   abandoned temp is reclaimed once too old to belong to a live write.
/// - **Un-drainable records are reaped, not skipped** (#161): anything
///   `pending` declines to emit is deleted, because none of it has an
///   address `remove` could ever clear. One exception — a *filesystem*
///   fault is not corruption, so an unreadable file is skipped and
///   retried. Malformed bytes are corruption and are reaped, which is why
///   `pending` reads bytes and decodes in Dart rather than calling
///   `readAsString` (see the sink's doc).
/// - **Operations are serialized**: `persist`, `pending`, and `remove` each
///   act on a pathname after an `await`, so interleaving them turns the
///   reap and the remove into time-of-check/time-of-use races that delete a
///   record written after the read they were based on.
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
  }) => QueuedFeedbackReport(
    report: report(key, message: message),
    serverId: serverId,
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

  group('FileFeedbackSink', () {
    test('is a FeedbackSink', () {
      expect(buildSink(), isA<FeedbackSink>());
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

    test('two overlapping persists of the same record both succeed — they '
        'do not share a temp path, so neither renames the other out from '
        'under it', () async {
      final sink = buildSink();

      // A resubmission racing a send still in flight, both falling back to
      // the queue. With a shared temp path the second rename fails on a
      // file the first already moved, and _queue reports a persistence
      // failure for a record that is in fact safely queued.
      await expectLater(
        Future.wait([
          sink.persist(record('key-a', message: 'first')),
          sink.persist(record('key-a', message: 'second')),
        ]),
        completes,
      );

      final pending = await sink.pending();
      expect(pending.map((r) => r.storageKey), ['key-a']);
      final names = tempDir
          .listSync()
          .map((e) => e.uri.pathSegments.last)
          .toList();
      expect(names, ['key-a.json']);
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
      await File(
        '${tempDir.path}/zzz-oldest.json',
      ).setLastModified(DateTime(2026, 1, 1));
      await File(
        '${tempDir.path}/aaa-newest.json',
      ).setLastModified(DateTime(2026, 1, 2));

      final pending = await sink.pending();

      expect(pending.map((r) => r.storageKey), [
        'zzz-oldest',
        'aaa-newest',
      ]);
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
        reason: 'the #161 decision is drop, not skip — a skipped file '
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
        reason: 'every abandoned temp has a distinct name, so never '
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
}
