import 'package:observability/observability.dart';

/// A [FeedbackService] that builds a minimal report and always reports sent.
///
/// Shared because five `bge_app_*` crash-flow suites had a byte-identical
/// private copy. [FeedbackService] is young — `drainPending` was added to it
/// after the first copies existed — and every method it gains costs one
/// hand-edit per copy, all of which must agree or the suites drift.
///
/// Deliberately not a mock: these suites assert on what the crash *flow*
/// does, and a stub with no verification surface keeps them from
/// accidentally asserting on the service instead.
class StubFeedbackService implements FeedbackService {
  @override
  FeedbackReport buildReport({
    required FeedbackCategory category,
    FeedbackSeverity? severity,
    String? title,
    String? errorMessage,
    String? stackTrace,
    String? userComment,
    String? clientRequestId,
  }) => FeedbackReport(
    category: category,
    severity: severity ?? FeedbackSeverity.critical,
    message: errorMessage ?? 'crash',
    stackTrace: stackTrace,
    title: title,
    clientRequestId: 'stub-key',
  );

  @override
  Future<FeedbackSubmitResult> submit(FeedbackReport report) async =>
      FeedbackSubmitResult.sent;

  @override
  Future<int> drainPending() async => 0;
}
