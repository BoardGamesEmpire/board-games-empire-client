import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_platform/native_platform.dart';
import 'package:observability/observability.dart';

/// Contract pinned:
///
/// - **Only user-approved reports reach this sink** (the #34 privacy
///   contract is upheld by the approval gate upstream); one JSON file
///   per record, named `<correlationKey>.json`.
/// - On-disk shape is the [QueuedFeedbackReport] envelope (#97): report
///   plus the `bgeServerId` it was approved for. Legacy #69 files hold a
///   bare [FeedbackReport] and decode as **untagged** records — they
///   drain instead of being stranded.
/// - **Lazy directory resolution**: the injected `directoryProvider`
///   (production default: a `path_provider`-backed subdirectory) is not
///   invoked at construction, so registering the sink in the root
///   module puts no plugin call on the boot hot path.
/// - Defensive reads: a corrupted file is skipped, not fatal — one bad
///   record must not hide the rest.
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
        correlationKey: key,
      );

  QueuedFeedbackReport record(
    String key, {
    String? serverId,
    String message = 'pending',
  }) => QueuedFeedbackReport(
    report: report(key, message: message),
    serverId: serverId,
  );

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
        'correlationKey', () async {
      final sink = buildSink();

      await sink.persist(record('key-a', serverId: 'srv-1'));

      final file = File('${tempDir.path}/key-a.json');
      expect(file.existsSync(), isTrue);
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(
        QueuedFeedbackReport.fromJson(decoded),
        record('key-a', serverId: 'srv-1'),
      );
    });

    test(
      'creates the directory on demand when it does not exist yet',
      () async {
        final nested = Directory('${tempDir.path}/feedback_reports');
        expect(nested.existsSync(), isFalse);
        final sink = buildSink(provider: () async => nested);

        await sink.persist(record('key-a'));

        expect(nested.existsSync(), isTrue);
        expect(await sink.pending(), hasLength(1));
      },
    );

    test('pending round-trips persisted records with their serverId '
        'tags', () async {
      final sink = buildSink();
      await sink.persist(record('key-a', serverId: 'srv-1', message: 'first'));
      await sink.persist(record('key-b', message: 'second'));

      final pending = await sink.pending();

      expect(pending, hasLength(2));
      final byKey = {for (final r in pending) r.correlationKey: r};
      expect(byKey.keys, containsAll(<String>['key-a', 'key-b']));
      expect(byKey['key-a']!.serverId, 'srv-1');
      expect(byKey['key-b']!.serverId, isNull);
    });

    test('pending decodes a legacy #69 bare-report file as an untagged '
        'record — pre-#97 queued reports drain instead of being '
        'stranded', () async {
      final sink = buildSink();
      // A file exactly as #69's persist wrote it: the report JSON, bare.
      await File(
        '${tempDir.path}/legacy.json',
      ).writeAsString(jsonEncode(report('legacy').toJson()));

      final pending = await sink.pending();

      expect(pending, hasLength(1));
      expect(pending.single.correlationKey, 'legacy');
      expect(pending.single.serverId, isNull);
      expect(pending.single.report, report('legacy'));
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

      expect(pending.map((r) => r.correlationKey), [
        'zzz-oldest',
        'aaa-newest',
      ]);
    });

    test('pending skips a decoded record with no correlationKey — it '
        'could never be removed after a send (poison record), so the '
        'rest of the queue still drains', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));
      // A legacy #69 bare-report file whose report carries no key —
      // decodes to a valid but un-removable record.
      const keyless = FeedbackReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        message: 'no key',
      );
      await File(
        '${tempDir.path}/orphan.json',
      ).writeAsString(jsonEncode(keyless.toJson()));

      final pending = await sink.pending();

      expect(pending.map((r) => r.correlationKey), ['key-a']);
    });

    test('pending skips a record whose inner correlationKey disagrees '
        'with its file name — remove() targets <key>.json, not this '
        'file, so it would be un-removable', () async {
      final sink = buildSink();
      // File named mismatch.json but the envelope inside is keyed 'other'.
      await File(
        '${tempDir.path}/mismatch.json',
      ).writeAsString(jsonEncode(record('other').toJson()));

      expect(await sink.pending(), isEmpty);
    });

    test('pending is empty when nothing was ever persisted (directory '
        'absent)', () async {
      final sink = buildSink(
        provider: () async => Directory('${tempDir.path}/never_created'),
      );

      expect(await sink.pending(), isEmpty);
    });

    test('pending skips a corrupted file instead of failing the whole '
        'read', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));
      await File(
        '${tempDir.path}/corrupt.json',
      ).writeAsString('not json at all');
      // Valid JSON that is neither an envelope nor a legacy report.
      await File(
        '${tempDir.path}/wrong_shape.json',
      ).writeAsString('{"neither": true}');

      final pending = await sink.pending();

      expect(pending.map((r) => r.correlationKey), ['key-a']);
    });

    test('remove deletes the record file', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));
      await sink.persist(record('key-b'));

      await sink.remove('key-a');

      expect(File('${tempDir.path}/key-a.json').existsSync(), isFalse);
      expect((await sink.pending()).map((r) => r.correlationKey), ['key-b']);
    });

    test('remove of an unknown key is a harmless no-op', () async {
      final sink = buildSink();
      await sink.persist(record('key-a'));

      await sink.remove('nope');

      expect(await sink.pending(), hasLength(1));
    });

    test('rejects a record without a correlationKey — files are keyed '
        'by it', () async {
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

    test('persist rejects a correlationKey containing path segments — no '
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

    test('remove rejects a correlationKey containing path segments — a '
        'crafted key cannot delete an arbitrary file', () async {
      final sink = buildSink();
      // A sibling file outside the "key" namespace that a traversal key
      // must not be able to reach.
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
