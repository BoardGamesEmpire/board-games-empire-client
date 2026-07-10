import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:native_platform/native_platform.dart';
import 'package:observability/observability.dart';

/// Red-phase tests for `FileFeedbackSink` (issue #69) — the durable
/// native `FeedbackSink`.
///
/// Contract pinned:
///
/// - **Only user-approved reports reach this sink** (the #34 privacy
///   contract is upheld by the approval gate upstream); one JSON file
///   per report, named `<correlationKey>.json`.
/// - **Lazy directory resolution**: the injected `directoryProvider`
///   (production default: a `path_provider`-backed subdirectory) is not
///   invoked at construction, so registering the sink in the root
///   module puts no plugin call on the boot hot path.
/// - Defensive reads: a corrupted file is skipped, not fatal — one bad
///   report must not hide the rest.
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

    test('persist writes one JSON file per report, named by '
        'correlationKey', () async {
      final sink = buildSink();

      await sink.persist(report('key-a'));

      final file = File('${tempDir.path}/key-a.json');
      expect(file.existsSync(), isTrue);
      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(FeedbackReport.fromJson(decoded), report('key-a'));
    });

    test(
      'creates the directory on demand when it does not exist yet',
      () async {
        final nested = Directory('${tempDir.path}/feedback_reports');
        expect(nested.existsSync(), isFalse);
        final sink = buildSink(provider: () async => nested);

        await sink.persist(report('key-a'));

        expect(nested.existsSync(), isTrue);
        expect(await sink.pending(), hasLength(1));
      },
    );

    test('pending round-trips persisted reports', () async {
      final sink = buildSink();
      await sink.persist(report('key-a', message: 'first'));
      await sink.persist(report('key-b', message: 'second'));

      final pending = await sink.pending();

      expect(
        pending.map((r) => r.correlationKey),
        containsAll(<String>['key-a', 'key-b']),
      );
      expect(pending, hasLength(2));
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
      await sink.persist(report('key-a'));
      await File(
        '${tempDir.path}/corrupt.json',
      ).writeAsString('not json at all');

      final pending = await sink.pending();

      expect(pending.map((r) => r.correlationKey), ['key-a']);
    });

    test('remove deletes the report file', () async {
      final sink = buildSink();
      await sink.persist(report('key-a'));
      await sink.persist(report('key-b'));

      await sink.remove('key-a');

      expect(File('${tempDir.path}/key-a.json').existsSync(), isFalse);
      expect((await sink.pending()).map((r) => r.correlationKey), ['key-b']);
    });

    test('remove of an unknown key is a harmless no-op', () async {
      final sink = buildSink();
      await sink.persist(report('key-a'));

      await sink.remove('nope');

      expect(await sink.pending(), hasLength(1));
    });

    test('rejects a report without a correlationKey — files are keyed '
        'by it', () async {
      final sink = buildSink();
      const keyless = FeedbackReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        message: 'pending',
      );

      await expectLater(sink.persist(keyless), throwsArgumentError);
    });
  });
}
