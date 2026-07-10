import 'package:observability/observability.dart';
import 'package:test/test.dart';

/// Red-phase tests for `MemoryFeedbackSink` (issue #69) — the pure-Dart
/// RAM implementation of `FeedbackSink`.
///
/// Two jobs: the **web stand-in** (no storage layer until #63 — an
/// approved-but-unsendable report survives within the session and is
/// lost on reload, and the user is told so), and `runBgeApp`'s
/// resolve-or-default fallback when a platform module registered no
/// sink. Lives in `observability` rather than `web_platform` because
/// nothing about a RAM sink is platform-specific.
void main() {
  FeedbackReport report(String key) => FeedbackReport(
    category: FeedbackCategory.bug,
    severity: FeedbackSeverity.low,
    message: 'pending',
    correlationKey: key,
  );

  group('MemoryFeedbackSink', () {
    test('is a FeedbackSink', () {
      expect(MemoryFeedbackSink(), isA<FeedbackSink>());
    });

    test('persist/pending round-trips reports', () async {
      final sink = MemoryFeedbackSink();

      await sink.persist(report('a'));
      await sink.persist(report('b'));

      final pending = await sink.pending();
      expect(pending.map((r) => r.correlationKey), ['a', 'b']);
    });

    test('pending returns a snapshot — mutating it does not affect the '
        'sink', () async {
      final sink = MemoryFeedbackSink();
      await sink.persist(report('a'));

      final first = await sink.pending()
        ..clear();
      expect(first, isEmpty);

      expect(await sink.pending(), hasLength(1));
    });

    test('remove deletes by correlationKey', () async {
      final sink = MemoryFeedbackSink();
      await sink.persist(report('a'));
      await sink.persist(report('b'));

      await sink.remove('a');

      expect((await sink.pending()).map((r) => r.correlationKey), ['b']);
    });

    test('remove of an unknown key is a harmless no-op', () async {
      final sink = MemoryFeedbackSink();
      await sink.persist(report('a'));

      await sink.remove('nope');

      expect(await sink.pending(), hasLength(1));
    });

    test('rejects a report without a correlationKey — the sink is keyed '
        'by it', () async {
      final sink = MemoryFeedbackSink();
      const keyless = FeedbackReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        message: 'pending',
      );

      await expectLater(sink.persist(keyless), throwsArgumentError);
    });
  });
}
