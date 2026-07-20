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
/// - The envelope's JSON is distinguishable from a legacy bare-report
///   map by the presence of the `report` key (the sink's legacy-decode
///   pivot).
void main() {
  const report = FeedbackReport(
    category: FeedbackCategory.crash,
    severity: FeedbackSeverity.critical,
    message: 'It broke',
    stackTrace: '#0 main (file.dart:1)',
    correlationKey: 'key-1',
  );

  group('QueuedFeedbackReport', () {
    test('exposes the report correlationKey as its own storage key', () {
      const record = QueuedFeedbackReport(report: report, serverId: 'srv-1');

      expect(record.correlationKey, 'key-1');
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

    test('nests the report as a map under the "report" key — the '
        'envelope-vs-legacy pivot the file sink relies on', () {
      const record = QueuedFeedbackReport(report: report, serverId: 'srv-1');

      final json = record.toJson();

      expect(json['report'], isA<Map<String, dynamic>>());
      expect(
        (json['report'] as Map<String, dynamic>)['correlationKey'],
        'key-1',
      );
      // The legacy bare-report shape has no 'report' key.
      expect(report.toJson().containsKey('report'), isFalse);
    });
  });
}
