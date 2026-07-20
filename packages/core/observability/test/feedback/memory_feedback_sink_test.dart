import 'package:observability/observability.dart';
import 'package:test/test.dart';

/// Contract pinned (#69, envelope shape #97): keyed by the report's
/// correlationKey, insertion-ordered pending, idempotent remove — the
/// same observable contract as `FileFeedbackSink`, minus durability.
void main() {
  QueuedFeedbackReport record(
    String key, {
    String? serverId,
    String message = 'pending',
  }) => QueuedFeedbackReport(
    report: FeedbackReport(
      category: FeedbackCategory.bug,
      severity: FeedbackSeverity.low,
      message: message,
      correlationKey: key,
    ),
    serverId: serverId,
  );

  group('MemoryFeedbackSink', () {
    test('is a FeedbackSink', () {
      expect(MemoryFeedbackSink(), isA<FeedbackSink>());
    });

    test('round-trips records with their serverId tag, oldest '
        'first', () async {
      final sink = MemoryFeedbackSink();
      await sink.persist(record('key-a', serverId: 'srv-1'));
      await sink.persist(record('key-b'));

      final pending = await sink.pending();

      expect(pending.map((r) => r.correlationKey), ['key-a', 'key-b']);
      expect(pending.first.serverId, 'srv-1');
      expect(pending.last.serverId, isNull);
    });

    test('persist with an existing key replaces the record without '
        'duplicating it', () async {
      final sink = MemoryFeedbackSink();
      await sink.persist(record('key-a', message: 'first'));
      await sink.persist(record('key-a', message: 'second'));

      final pending = await sink.pending();

      expect(pending, hasLength(1));
      expect(pending.single.report.message, 'second');
    });

    test('remove deletes the record; unknown keys are a no-op', () async {
      final sink = MemoryFeedbackSink();
      await sink.persist(record('key-a'));
      await sink.persist(record('key-b'));

      await sink.remove('key-a');
      await sink.remove('nope');

      expect((await sink.pending()).map((r) => r.correlationKey), ['key-b']);
    });

    test('rejects a record whose report has no correlationKey — the '
        'sink is keyed by it', () async {
      final sink = MemoryFeedbackSink();
      const keyless = QueuedFeedbackReport(
        report: FeedbackReport(
          category: FeedbackCategory.bug,
          severity: FeedbackSeverity.low,
          message: 'pending',
        ),
      );

      await expectLater(sink.persist(keyless), throwsArgumentError);
    });
  });
}
