import 'package:cuid2/cuid2.dart';

import '../breadcrumbs/breadcrumb.dart';
import 'feedback_category.dart';
import 'feedback_constants.dart';
import 'feedback_environment.dart';
import 'feedback_report.dart';
import 'feedback_service.dart';
import 'feedback_sink.dart';
import 'feedback_transport.dart';
import 'feedback_severity.dart';

/// Device-global [FeedbackService] registered in the app-scope root
/// container (#72, #69).
///
/// All collaborators are injected as providers so this stays pure Dart
/// and unit-testable without platform machinery:
///
/// - [breadcrumbSource] — the shell breadcrumb ring, snapshotted at
///   build time (wired to `ShellObservability.breadcrumbs.snapshot`).
/// - [environmentSource] — the [FeedbackEnvironment] assembled at the
///   composition root (BuildInfo/platform/locale live there).
/// - [transportResolver] — yields the active server's [FeedbackTransport]
///   or null. Late-bound because capture is device-global and pre-auth
///   while the network leg is per-server and post-auth; the resolver is
///   re-read on every [submit]/[drainPending].
/// - [sink] — the durable store for user-approved-but-unsent reports.
/// - [correlationKeyGenerator] — defaults to cuid2 ([cuid]), the repo's
///   id convention.
class FeedbackServiceImpl implements FeedbackService {
  FeedbackServiceImpl({
    required List<Breadcrumb> Function() breadcrumbSource,
    required FeedbackEnvironment Function() environmentSource,
    required FeedbackTransport? Function() transportResolver,
    required FeedbackSink sink,
    String Function()? correlationKeyGenerator,
  }) : _breadcrumbSource = breadcrumbSource,
       _environmentSource = environmentSource,
       _transportResolver = transportResolver,
       _sink = sink,
       _correlationKeyGenerator = correlationKeyGenerator ?? cuid;

  final List<Breadcrumb> Function() _breadcrumbSource;
  final FeedbackEnvironment Function() _environmentSource;
  final FeedbackTransport? Function() _transportResolver;
  final FeedbackSink _sink;
  final String Function() _correlationKeyGenerator;

  @override
  FeedbackReport buildReport({
    required FeedbackCategory category,
    FeedbackSeverity? severity,
    String? title,
    String? errorMessage,
    String? stackTrace,
    String? userComment,
    String? correlationKey,
  }) {
    final message = _composeMessage(errorMessage, userComment);
    if (message == null) {
      throw ArgumentError(
        'buildReport requires a non-empty errorMessage or userComment '
        '(the report message must not be empty)',
      );
    }
    final environment = _environmentSource();
    return FeedbackReport(
      category: category,
      severity: severity,
      title: title,
      message: message,
      stackTrace: _truncateStackTrace(stackTrace),
      appVersion: environment.appVersion,
      platform: environment.platform,
      locale: environment.locale,
      deviceInfo: environment.deviceInfo,
      correlationKey: correlationKey ?? _correlationKeyGenerator(),
      breadcrumbs: _trimBreadcrumbs(_breadcrumbSource()),
    );
  }

  @override
  Future<FeedbackSubmitResult> submit(FeedbackReport report) async {
    final violations = report.validate();
    if (violations.isNotEmpty) {
      throw FeedbackSubmissionException(
        'Invalid feedback report: ${violations.join('; ')}',
      );
    }

    final transport = _transportResolver();
    if (transport == null) {
      return _queue(report, cause: null);
    }

    try {
      await transport.send(report);
      return FeedbackSubmitResult.sent;
    } on Object catch (error) {
      // Transport failed — fall back to the durable sink so an approved
      // report is never lost to a transient network failure.
      return _queue(report, cause: error);
    }
  }

  @override
  Future<int> drainPending() async {
    final transport = _transportResolver();
    if (transport == null) return 0;

    final pending = await _sink.pending();
    var sent = 0;
    for (final report in pending) {
      try {
        await transport.send(report);
      } on Object {
        // Best-effort: stop at the first failure, leaving this report
        // and the rest persisted for the next drain.
        break;
      }
      final key = report.correlationKey;
      if (key != null) await _sink.remove(key);
      sent++;
    }
    return sent;
  }

  /// Persists [report] to the sink, returning [FeedbackSubmitResult.queued];
  /// if the sink itself fails, surfaces [FeedbackSubmissionException]
  /// (carrying the original transport [cause] when there was one).
  Future<FeedbackSubmitResult> _queue(
    FeedbackReport report, {
    required Object? cause,
  }) async {
    try {
      await _sink.persist(report);
      return FeedbackSubmitResult.queued;
    } on Object catch (sinkError) {
      throw FeedbackSubmissionException(
        cause == null
            ? 'Feedback could not be queued'
            : 'Feedback submission failed and could not be queued',
        cause: cause ?? sinkError,
      );
    }
  }

  String? _composeMessage(String? errorMessage, String? userComment) {
    final error = errorMessage?.trim();
    final comment = userComment?.trim();
    final hasError = error != null && error.isNotEmpty;
    final hasComment = comment != null && comment.isNotEmpty;
    if (hasError && hasComment) return '$error\n\n$comment';
    if (hasError) return error;
    if (hasComment) return comment;
    return null;
  }

  /// Tail-preserving truncation to [FeedbackConstants.maxStackTraceLength]
  /// (keeps the trace's tail).
  String? _truncateStackTrace(String? trace) {
    if (trace == null) return null;
    const max = FeedbackConstants.maxStackTraceLength;
    if (trace.length <= max) return trace;
    return trace.substring(trace.length - max);
  }

  /// Trims [crumbs] oldest-first until the serialized trail fits
  /// [FeedbackConstants.maxBreadcrumbsBytes]; the newest survive. Runs
  /// once per report build (not a hot path), so the repeated
  /// serialization as it drops the oldest is acceptable for the bounded
  /// ring.
  List<Breadcrumb> _trimBreadcrumbs(List<Breadcrumb> crumbs) {
    final kept = List<Breadcrumb>.of(crumbs);
    while (kept.isNotEmpty &&
        FeedbackReport.breadcrumbsByteSize(kept) >
            FeedbackConstants.maxBreadcrumbsBytes) {
      kept.removeAt(0);
    }
    return kept;
  }
}
