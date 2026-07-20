import 'package:cuid2/cuid2.dart';

import '../breadcrumbs/breadcrumb.dart';
import '../logging/bge_logger.dart';
import 'feedback_category.dart';
import 'feedback_constants.dart';
import 'feedback_environment.dart';
import 'feedback_report.dart';
import 'feedback_service.dart';
import 'feedback_severity.dart';
import 'feedback_sink.dart';
import 'feedback_target.dart';
import 'queued_feedback_report.dart';

/// Device-global [FeedbackService] registered in the app-scope root
/// container (#72, #69, #97).
///
/// All collaborators are injected as providers so this stays pure Dart
/// and unit-testable without platform machinery:
///
/// - [breadcrumbSource] — the shell breadcrumb ring, snapshotted at
///   build time (wired to `ShellObservability.breadcrumbs.snapshot`).
/// - [environmentSource] — the [FeedbackEnvironment] assembled at the
///   composition root (BuildInfo/platform/locale live there).
/// - [targetResolver] — yields the active server's [FeedbackTarget]
///   (its `bgeServerId`, plus its transport when authenticated) or null.
///   Late-bound because capture is device-global and pre-auth while the
///   network leg is per-server and post-auth; re-read on every
///   [submit]/[drainPending] (#97).
/// - [sink] — the durable store for user-approved-but-unsent reports,
///   as [QueuedFeedbackReport] records tagged with their server.
/// - [correlationKeyGenerator] — defaults to cuid2 ([cuid]), the repo's
///   id convention.
class FeedbackServiceImpl implements FeedbackService {
  FeedbackServiceImpl({
    required List<Breadcrumb> Function() breadcrumbSource,
    required FeedbackEnvironment Function() environmentSource,
    required FeedbackTargetResolver targetResolver,
    required FeedbackSink sink,
    String Function()? correlationKeyGenerator,
    BgeLogger? logger,
  }) : _breadcrumbSource = breadcrumbSource,
       _environmentSource = environmentSource,
       _targetResolver = targetResolver,
       _sink = sink,
       _correlationKeyGenerator = correlationKeyGenerator ?? cuid,
       _logger = logger ?? BgeLogger('bge.observability.feedback');

  final List<Breadcrumb> Function() _breadcrumbSource;
  final FeedbackEnvironment Function() _environmentSource;
  final FeedbackTargetResolver _targetResolver;
  final FeedbackSink _sink;
  final String Function() _correlationKeyGenerator;
  final BgeLogger _logger;

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
      // A cap-violating report is permanently unsubmittable — retrying
      // the identical payload can never succeed (#97 taxonomy).
      throw FeedbackPermanentSubmissionException(
        'Invalid feedback report: ${violations.join('; ')}',
      );
    }
    final correlationKey = report.correlationKey;
    if (correlationKey == null || correlationKey.isEmpty) {
      // Also a client-side contract violation, caught before any I/O:
      // the sink is keyed by the correlationKey, so a keyless report
      // would otherwise fail *at queue time* and masquerade as a
      // FeedbackPersistenceException — a sink fault it isn't.
      // [buildReport] always supplies a key; only hand-built reports
      // can land here.
      throw const FeedbackPermanentSubmissionException(
        'Invalid feedback report: a correlationKey is required '
        '(buildReport generates one)',
      );
    }
    if (correlationKey.contains('/') ||
        correlationKey.contains(r'\') ||
        correlationKey.contains('..')) {
      // Same misclassification hazard as the keyless case: the key is a
      // plain storage/idempotency token (cuid2 from [buildReport]), and
      // durable sinks legitimately reject path segments in it
      // (FileFeedbackSink interpolates the key into a file name).
      // Rejecting the shape here, permanently and before any I/O, keeps
      // that from surfacing as a phantom persistence failure.
      throw const FeedbackPermanentSubmissionException(
        'Invalid feedback report: correlationKey must not contain '
        'path segments',
      );
    }

    final target = _targetResolver.resolve();
    final transport = target?.transport;
    if (target == null || transport == null) {
      // No active server, or active but unauthenticated. Queue, tagged
      // with the server when one exists (#97: the tag exists even
      // without a transport, so the record can never drain into the
      // wrong server later).
      return _queue(report, serverId: target?.serverId, transportCause: null);
    }

    try {
      await transport.send(report);
      return FeedbackSubmitResult.sent;
    } on FeedbackPermanentSubmissionException {
      // 400 / 403 / other 4xx: retrying can never succeed. Queueing
      // would mislead the user ("will be sent later") and build an
      // un-drainable backlog — surface it instead; the prompt renders
      // the rejected state (#97).
      rethrow;
    } on Object catch (error) {
      // Transient (offline / timeout / 401 / 408 / 429 / 5xx) — and,
      // defensively, anything unclassified a transport leaked in breach
      // of its contract: fall back to the durable sink so an approved
      // report is never lost to a recoverable failure.
      return _queue(report, serverId: target.serverId, transportCause: error);
    }
  }

  /// The in-flight drain, when one is running. Overlapping calls (the
  /// trigger fires on every authenticated signal, and duplicates are
  /// documented) coalesce into it instead of racing: two concurrent
  /// runs would both read the same [FeedbackSink.pending] snapshot
  /// before either removes anything and re-POST every record — harmless
  /// server-side (correlationKey idempotency) but redundant network
  /// work and double-counted results. A signal arriving mid-drain gets
  /// the in-flight run's count; the next signal after completion starts
  /// a fresh one.
  Future<int>? _activeDrain;

  @override
  Future<int> drainPending() =>
      _activeDrain ??= _drainPending().whenComplete(() => _activeDrain = null);

  Future<int> _drainPending() async {
    final target = _targetResolver.resolve();
    final transport = target?.transport;
    if (target == null || transport == null) return 0;

    final pending = await _sink.pending();
    var sent = 0;
    for (final record in pending) {
      // #97 per-server drain safety: a record tagged for a different
      // server is never touched. Untagged records (approved with no
      // active server — device-global diagnostics) drain here.
      final recordServerId = record.serverId;
      if (recordServerId != null && recordServerId != target.serverId) {
        continue;
      }

      try {
        await transport.send(record.report);
      } on FeedbackPermanentSubmissionException catch (error) {
        // Permanently rejected: drop it — keeping it is exactly the
        // un-drainable backlog #97 exists to prevent — breadcrumb the
        // drop (warn survives the release sink threshold), continue.
        _logger.warn(
          'Dropping permanently rejected queued feedback report',
          error: error,
          context: {
            'correlationKey': record.correlationKey,
            'statusCode': error.statusCode,
          },
        );
        await _removeRecord(record);
        continue;
      } on Object {
        // Transient (including 429 — respect the backend throttle) or
        // unexpected: stop, leaving this record and the rest persisted
        // for the next drain.
        break;
      }
      await _removeRecord(record);
      sent++;
    }
    return sent;
  }

  /// Removes a drained record, best-effort. A keyless record has no
  /// address (durable sinks filter these out of pending()); any other
  /// removal fault — an unusable key reaching a strict sink, a
  /// transient I/O error — is logged and swallowed rather than allowed
  /// to abort the drain: the record simply re-sends on the next drain,
  /// and correlationKey idempotency dedupes it server-side.
  Future<void> _removeRecord(QueuedFeedbackReport record) async {
    final key = record.correlationKey;
    if (key == null || key.isEmpty) return;
    try {
      await _sink.remove(key);
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Failed to remove drained feedback report',
        error: error,
        stackTrace: stackTrace,
        context: {'correlationKey': key},
      );
    }
  }

  /// Persists [report] to the sink as a [QueuedFeedbackReport] tagged
  /// with [serverId], returning [FeedbackSubmitResult.queued]; if the
  /// sink itself fails, surfaces [FeedbackPersistenceException] — the
  /// third failure mode ("couldn't even persist"), distinct from any
  /// server rejection (#97). The sink failure is the primary `cause` (it
  /// is the reason queueing failed, and usually the more actionable root
  /// cause); a prior transport failure ([transportCause]) is carried
  /// alongside for telemetry.
  Future<FeedbackSubmitResult> _queue(
    FeedbackReport report, {
    required String? serverId,
    required Object? transportCause,
  }) async {
    try {
      await _sink.persist(
        QueuedFeedbackReport(report: report, serverId: serverId),
      );
      return FeedbackSubmitResult.queued;
    } on Object catch (sinkError) {
      throw FeedbackPersistenceException(
        transportCause == null
            ? 'Feedback could not be queued'
            : 'Feedback submission failed and could not be queued '
                  '(transport error: $transportCause)',
        cause: sinkError,
        transportCause: transportCause,
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
