import 'dart:convert';

import 'package:observability/observability.dart';
import 'package:test/test.dart';

/// Red-phase tests for the `FeedbackReport` model drift fixes (issue
/// #69).
///
/// The backend `CreateFeedbackReportDto` carries a **dedicated
/// `stackTrace` field** (backend #77; cap 32,768 — "client truncates
/// tail-preserving, the backend rejects anything past it") and a
/// byte-capped `breadcrumbs` array (backend #86; 64 KB serialized
/// UTF-8). The client model predates both: it has no `stackTrace`
/// field, and `FeedbackConstants` lacks both caps. These tests pin the
/// corrected shape; the stale "weave the trace into message" guidance
/// in the `FeedbackService` docstring is corrected in the same change.
void main() {
  Breadcrumb crumb(String message) => Breadcrumb(
    timestamp: DateTime.utc(2026, 7, 9),
    level: BgeLogLevel.info,
    loggerName: 'bge.test',
    message: message,
  );

  int serializedBytes(List<Breadcrumb> crumbs) =>
      utf8.encode(jsonEncode(crumbs.map((c) => c.toJson()).toList())).length;

  group('FeedbackConstants (backend protocol caps)', () {
    test('carries the dedicated stack-trace cap', () {
      expect(FeedbackConstants.maxStackTraceLength, 32768);
    });

    test('carries the serialized-breadcrumbs byte cap', () {
      expect(FeedbackConstants.maxBreadcrumbsBytes, 65536);
    });
  });

  group('FeedbackReport.stackTrace', () {
    test('is carried as a dedicated field, not woven into message', () {
      const report = FeedbackReport(
        category: FeedbackCategory.crash,
        severity: FeedbackSeverity.critical,
        message: 'It broke',
        stackTrace: '#0 main (file.dart:1)',
      );

      expect(report.stackTrace, '#0 main (file.dart:1)');
      expect(report.message, isNot(contains('#0 main')));
    });

    test('is optional (user-initiated reports carry none)', () {
      const report = FeedbackReport(
        category: FeedbackCategory.featureRequest,
        message: 'Please add dark mode',
      );

      expect(report.stackTrace, isNull);
    });

    test('round-trips through JSON', () {
      const report = FeedbackReport(
        category: FeedbackCategory.crash,
        severity: FeedbackSeverity.critical,
        message: 'It broke',
        stackTrace: '#0 main (file.dart:1)\n#1 run (file.dart:9)',
      );

      expect(FeedbackReport.fromJson(report.toJson()), report);
    });

    test('validate flags a trace past the cap and passes one at it', () {
      final atCap = FeedbackReport(
        category: FeedbackCategory.crash,
        severity: FeedbackSeverity.critical,
        message: 'It broke',
        stackTrace: 'x' * FeedbackConstants.maxStackTraceLength,
      );
      final pastCap = FeedbackReport(
        category: FeedbackCategory.crash,
        severity: FeedbackSeverity.critical,
        message: 'It broke',
        stackTrace: 'x' * (FeedbackConstants.maxStackTraceLength + 1),
      );

      expect(atCap.validate(), isNot(contains(contains('stackTrace'))));
      expect(pastCap.validate(), contains(contains('stackTrace')));
      expect(pastCap.isValid, isFalse);
    });
  });

  group('FeedbackReport breadcrumb byte cap', () {
    test('validate flags a breadcrumb list past the serialized byte cap', () {
      // Ten ~10 KB crumbs serialize well past the 64 KB cap.
      final crumbs = List.generate(10, (i) => crumb('x' * 10000));
      assert(serializedBytes(crumbs) > FeedbackConstants.maxBreadcrumbsBytes);

      final report = FeedbackReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        message: 'It misbehaved',
        breadcrumbs: crumbs,
      );

      expect(report.validate(), contains(contains('breadcrumbs')));
      expect(report.isValid, isFalse);
    });

    test('validate passes a breadcrumb list under the cap', () {
      final report = FeedbackReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        message: 'It misbehaved',
        breadcrumbs: [crumb('small'), crumb('also small')],
      );

      expect(report.validate(), isNot(contains(contains('breadcrumbs'))));
    });
  });
}
