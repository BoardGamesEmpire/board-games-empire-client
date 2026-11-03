import 'dart:convert';

import 'package:observability/observability.dart';
import 'package:test/test.dart';

/// Contract pinned (#97):
///
/// - The envelope carries the report **verbatim** plus the client-side
///   `serverId` tag (`bgeServerId`, nullable) — the tag lives here, not
///   on `FeedbackReport`, so the wire DTO the transport POSTs stays a
///   pure mirror of the backend's `CreateFeedbackReportDto`.
/// - JSON round-trips losslessly, tagged and untagged, so the file sink
///   can store the envelope as-is.
/// - The report nests under a `report` key rather than being flattened
///   alongside `serverId`, so the wire DTO stays recoverable verbatim.
///   The file sink's legacy bare-report decode path, which used this key
///   as its pivot, was removed with #161 — a bare-report file is now
///   reaped, so the shape assertion stands on its own terms.
void main() {
  const report = FeedbackReport(
    category: FeedbackCategory.crash,
    severity: FeedbackSeverity.critical,
    message: 'It broke',
    stackTrace: '#0 main (file.dart:1)',
    clientRequestId: 'key-1',
  );

  group('QueuedFeedbackReport', () {
    test('exposes the report clientRequestId as its own storage key', () {
      const record = QueuedFeedbackReport(report: report, serverId: 'srv-1');

      expect(record.storageKey, 'key-1');
    });

    test('serverId defaults to null — an untagged, device-global '
        'record', () {
      const record = QueuedFeedbackReport(report: report);

      expect(record.serverId, isNull);
    });

    test('JSON round-trips a tagged record losslessly', () {
      const record = QueuedFeedbackReport(report: report, serverId: 'srv-1');

      final decoded = QueuedFeedbackReport.fromJson(
        jsonDecode(jsonEncode(record.toJson())) as Map<String, dynamic>,
      );

      expect(decoded, record);
      expect(decoded.serverId, 'srv-1');
      expect(decoded.report, report);
    });

    test('JSON round-trips an untagged record losslessly', () {
      const record = QueuedFeedbackReport(report: report);

      final decoded = QueuedFeedbackReport.fromJson(
        jsonDecode(jsonEncode(record.toJson())) as Map<String, dynamic>,
      );

      expect(decoded, record);
      expect(decoded.serverId, isNull);
    });

    test('nests the report as a map under the "report" key rather than '
        'flattening it alongside serverId', () {
      const record = QueuedFeedbackReport(report: report, serverId: 'srv-1');

      final json = record.toJson();

      expect(json['report'], isA<Map<String, dynamic>>());
      expect(
        (json['report'] as Map<String, dynamic>)['clientRequestId'],
        'key-1',
      );
      // A bare report is not mistakable for an envelope: it has no
      // 'report' key, so decoding one as an envelope fails and the file
      // sink reaps it (#161) rather than accepting it.
      expect(report.toJson().containsKey('report'), isFalse);
    });
  });

  group('keysToEvict (#387)', () {
    DateTime t(int i) => DateTime.utc(2026).add(Duration(minutes: i));
    int byKey(String a, String b) => a.compareTo(b);
    const max = QueuedFeedbackReport.maxQueuedReports;

    test('returns nothing at or under the bound', () {
      final entries = [for (var i = 0; i < max; i++) ('k$i', t(i))];

      expect(
        QueuedFeedbackReport.keysToEvict(entries, tieBreak: byKey),
        isEmpty,
      );
    });

    test('returns the oldest excess, oldest first', () {
      // Ages 0..max+1 in a fixed, hand-written non-sorted order: odds
      // descending, then evens ascending.
      final ages = [
        for (var i = max + 1; i >= 0; i--)
          if (i.isOdd) i,
        for (var i = 0; i <= max + 1; i++)
          if (i.isEven) i,
      ];
      expect(ages.length, max + 2);
      final entries = [for (final i in ages) ('k$i', t(i))];

      expect(QueuedFeedbackReport.keysToEvict(entries, tieBreak: byKey), [
        'k0',
        'k1',
      ]);
    });

    test('breaks equal ages with tieBreak', () {
      final entries = [
        for (var i = max; i >= 0; i--)
          ('k${i.toString().padLeft(3, '0')}', t(0)),
      ];

      expect(QueuedFeedbackReport.keysToEvict(entries, tieBreak: byKey), [
        'k000',
      ]);
    });

    test('never returns exempt, even when it is the oldest, and still '
        'counts it', () {
      final entries = [for (var i = 0; i <= max; i++) ('k$i', t(i))];

      expect(
        QueuedFeedbackReport.keysToEvict(
          entries,
          exempt: 'k0',
          tieBreak: byKey,
        ),
        ['k1'],
      );
    });

    test('an exempt key alone is never returned', () {
      // With unique keys this cannot arise at the real bound: the candidates
      // always cover the excess. Duplicated keys make the one over-bound
      // entry set consist only of the exempt key, so this pins the exempt
      // filter, not the at-or-under-bound short-circuit, as what refuses it.
      expect(
        QueuedFeedbackReport.keysToEvict(
          [for (var i = 0; i <= max; i++) ('only', t(i))],
          exempt: 'only',
          tieBreak: byKey,
        ),
        isEmpty,
      );
    });
  });
}
