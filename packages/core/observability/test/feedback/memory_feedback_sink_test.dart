import 'package:observability/observability.dart';
import 'package:test/test.dart';

/// Contract pinned (#69, envelope shape #97): keyed by the report's
/// storage key, insertion-ordered pending, idempotent remove — the
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
      clientRequestId: key,
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

      expect(pending.map((r) => r.storageKey), ['key-a', 'key-b']);
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

      expect((await sink.pending()).map((r) => r.storageKey), ['key-b']);
    });

    test('rejects a record whose report has no clientRequestId — the '
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

  group('the cap (#359)', () {
    QueuedFeedbackReport record(String key, {DateTime? queuedAt}) =>
        QueuedFeedbackReport(
          report: FeedbackReport(
            category: FeedbackCategory.bug,
            severity: FeedbackSeverity.low,
            message: 'queued',
            clientRequestId: key,
          ),
          queuedAt: queuedAt,
        );

    test('holds at most maxQueuedReports', () async {
      final sink = MemoryFeedbackSink();
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports + 10; i++) {
        await sink.persist(
          record(
            'k$i',
            queuedAt: DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
          ),
        );
      }

      final pending = await sink.pending();

      expect(pending, hasLength(QueuedFeedbackReport.maxQueuedReports));
    });

    test('evicts oldest-first by queuedAt, not by insertion order', () async {
      final sink = MemoryFeedbackSink();
      // Inserted newest-first, so insertion order and age disagree: k0 is
      // the youngest stored record and the LAST one inserted is the oldest.
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        final oldest = QueuedFeedbackReport.maxQueuedReports - 1;
        await sink.persist(
          record(
            'k$i',
            queuedAt: DateTime.utc(2026, 6, 1).subtract(Duration(minutes: i)),
          ),
        );
        if (i == oldest) break;
      }
      // A brand-new record tips it over the cap.
      await sink.persist(
        record('newcomer', queuedAt: DateTime.utc(2026, 9, 11)),
      );

      final keys = (await sink.pending()).map((r) => r.storageKey).toSet();

      expect(keys, hasLength(QueuedFeedbackReport.maxQueuedReports));
      // Keyed on insertion order, 'k0' would have gone; by age it is the
      // youngest stored record and the last-inserted one is the oldest.
      expect(keys, contains('k0'));
      expect(
        keys,
        isNot(contains('k${QueuedFeedbackReport.maxQueuedReports - 1}')),
      );
      expect(keys, contains('newcomer'));
    });

    test('never evicts the record it was just handed — persist completing '
        'has to mean the record is stored', () async {
      final sink = MemoryFeedbackSink();
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        await sink.persist(record('k$i', queuedAt: DateTime.utc(2026, 6, 1)));
      }
      // A clock that stepped backwards makes the new record look oldest.
      await sink.persist(record('backdated', queuedAt: DateTime.utc(1999)));

      final keys = (await sink.pending()).map((r) => r.storageKey).toSet();

      expect(keys, contains('backdated'));
      expect(keys, hasLength(QueuedFeedbackReport.maxQueuedReports));
    });

    test('a record with no queuedAt is treated as oldest — it predates the '
        'field, so it genuinely is', () async {
      final sink = MemoryFeedbackSink();
      await sink.persist(record('legacy'));
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        await sink.persist(
          record(
            'k$i',
            queuedAt: DateTime.utc(2020, 1, 1).add(Duration(minutes: i)),
          ),
        );
      }

      final keys = (await sink.pending()).map((r) => r.storageKey).toSet();

      expect(keys, isNot(contains('legacy')));
      expect(keys, hasLength(QueuedFeedbackReport.maxQueuedReports));
    });

    test('re-persisting an existing key does not grow the queue', () async {
      final sink = MemoryFeedbackSink();
      for (var i = 0; i < QueuedFeedbackReport.maxQueuedReports; i++) {
        await sink.persist(record('k$i', queuedAt: DateTime.utc(2026, 1, 1)));
      }
      await sink.persist(record('k0', queuedAt: DateTime.utc(2026, 1, 1)));

      expect(
        await sink.pending(),
        hasLength(QueuedFeedbackReport.maxQueuedReports),
      );
      expect((await sink.pending()).map((r) => r.storageKey), contains('k0'));
    });
  });
}
