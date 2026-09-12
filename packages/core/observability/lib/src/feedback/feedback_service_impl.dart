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
/// - [clientRequestIdGenerator] — defaults to cuid2 ([cuid]), the repo's
///   id convention.
class FeedbackServiceImpl implements FeedbackService {
  FeedbackServiceImpl({
    required this._breadcrumbSource,
    required this._environmentSource,
    required this._targetResolver,
    required this._sink,
    String Function()? clientRequestIdGenerator,
    DateTime Function()? now,
    BgeLogger? logger,
  }) : _clientRequestIdGenerator = clientRequestIdGenerator ?? cuid,
       _now = now ?? DateTime.now,
       _logger = logger ?? BgeLogger('bge.observability.feedback');

  final List<Breadcrumb> Function() _breadcrumbSource;
  final FeedbackEnvironment Function() _environmentSource;
  final FeedbackTargetResolver _targetResolver;
  final FeedbackSink _sink;
  final String Function() _clientRequestIdGenerator;

  /// Injected so a test can pin `queuedAt` / `lastAttemptAt`; defaults to
  /// [DateTime.now].
  final DateTime Function() _now;
  final BgeLogger _logger;

  @override
  FeedbackReport buildReport({
    required FeedbackCategory category,
    FeedbackSeverity? severity,
    String? title,
    String? errorMessage,
    String? stackTrace,
    String? userComment,
    String? clientRequestId,
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
      clientRequestId: clientRequestId ?? _clientRequestIdGenerator(),
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
    final clientRequestId = report.clientRequestId;
    if (clientRequestId == null || clientRequestId.isEmpty) {
      // Also a client-side contract violation, caught before any I/O:
      // the sink addresses a record by this value (via
      // QueuedFeedbackReport.storageKey), so a keyless report would
      // otherwise fail *at queue time* and masquerade as a
      // FeedbackPersistenceException — a sink fault it isn't.
      // [buildReport] always supplies one; only hand-built reports can
      // land here.
      throw const FeedbackPermanentSubmissionException(
        'Invalid feedback report: a clientRequestId is required '
        '(buildReport generates one)',
      );
    }
    if (clientRequestId.contains('/') ||
        clientRequestId.contains(r'\') ||
        clientRequestId.contains('..')) {
      // Same misclassification hazard as the keyless case. The value is
      // a plain token (cuid2 from [buildReport]) that also has to serve
      // as the record's storage address, and durable sinks legitimately
      // reject path segments in an address (FileFeedbackSink interpolates
      // it into a file name). Rejecting the shape here, permanently and
      // before any I/O, keeps that from surfacing as a phantom
      // persistence failure.
      throw const FeedbackPermanentSubmissionException(
        'Invalid feedback report: clientRequestId must not contain '
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
  /// server-side (`clientRequestId` idempotency, wired by backend #251)
  /// but redundant network work and double-counted results. A signal
  /// arriving mid-drain gets the in-flight run's count; the next signal
  /// after completion starts a fresh one.
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
    final exhausted = <QueuedFeedbackReport>[];
    for (final record in pending) {
      // #97 per-server drain safety: a record tagged for a different
      // server is never touched. Untagged records (approved with no
      // active server — device-global diagnostics) drain here.
      final recordServerId = record.serverId;
      if (recordServerId != null && recordServerId != target.serverId) {
        continue;
      }

      // Out of attempts: keep it, skip it, and let the sink's cap be the
      // only thing that ever deletes it (#359 **D3**). Skipping rather
      // than breaking is what stops one spent record at the head of the
      // queue from re-creating the stall this bound exists to remove.
      if (record.isExhausted) {
        exhausted.add(record);
        continue;
      }

      // Still cooling down from its last unverified answer. Skipped without
      // being sent, so `maxRetries` measures elapsed time rather than how
      // often the drain happened to fire — see
      // [QueuedFeedbackReport.retryCooldown].
      if (!record.isRetryableAt(_now())) continue;

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
            'clientRequestId': record.storageKey,
            'statusCode': error.statusCode,
          },
        );
        await _removeRecord(record);
        continue;
      } on FeedbackUnverifiedDeliveryException catch (error) {
        // A 2xx this client could not verify (#358, #363). Unlike every
        // other transient it is a statement about ONE response, not about
        // the server or the network, so the run continues — but it also
        // need not self-clear (a permanently interposed proxy answers every
        // record identically), which is why the attempt is counted (#359
        // **D2**, **D4**).
        final counted = await _countFailedAttempt(record, error);
        // A record that spends its last attempt *here* has the same claim
        // on revival as one that arrived exhausted: a sibling delivering on
        // this transport disproves the hypothesis either way. Leaving these
        // out strands the last record standing — it exhausts on a run that
        // also delivers, and on every later run there is no sibling left to
        // succeed, so `sent` stays 0 and [_revive] never fires again.
        if (counted != null && counted.isExhausted) exhausted.add(counted);
        continue;
      } on Object {
        // Throttle (429), offline, 5xx, or unexpected: all statements about
        // the server or the connection, so every record behind this one
        // would fail the same way. Stop, count nothing — a week offline must
        // not exhaust a record — and leave the rest persisted for the next
        // drain (#359 **D4**).
        break;
      }
      await _removeRecord(record);
      sent++;
    }

    if (sent > 0) await _revive(exhausted);
    return sent;
  }

  /// Clears the retry count on records that had run out of attempts, after
  /// another record delivered successfully in the same run.
  ///
  /// The bound exists to stop a report being retried forever against an
  /// endpoint that answers every POST with something other than the API
  /// (#359 **D1**). A sibling that just delivered on this same transport
  /// disproves that hypothesis outright — the path demonstrably works right
  /// now — so continuing to skip these would strand user-approved reports
  /// on a healthy network until the sink's cap deleted them, having never
  /// offered them to a server that would have taken them.
  ///
  /// Runs after the loop rather than inside it because a record can be
  /// skipped before the delivery that vindicates it; these are picked up on
  /// the next drain.
  ///
  /// A record that genuinely cannot be delivered while its siblings can will
  /// re-exhaust, at [QueuedFeedbackReport.maxRetries] attempts spread by
  /// [QueuedFeedbackReport.retryCooldown] each time round. That is a slow
  /// cycle rather than a hard stop, and it is the right trade: the failure
  /// this bucket describes is a property of the *response*, so a record
  /// failing alone is anomalous enough to be worth re-offering.
  Future<void> _revive(List<QueuedFeedbackReport> exhausted) async {
    for (final record in exhausted) {
      try {
        await _sink.persist(
          record.copyWith(retryCount: 0, lastAttemptAt: null),
        );
      } on Object catch (error, stackTrace) {
        // Best-effort, as everywhere else on this path: the record keeps its
        // spent count and is reconsidered on the next successful drain.
        _logger.warn(
          'Failed to clear the retry bound on a queued feedback report',
          error: error,
          stackTrace: stackTrace,
          context: {'clientRequestId': record.storageKey},
        );
      }
    }
  }

  /// Counts one unverified-delivery attempt against [record] and persists
  /// the result, so the bound survives a restart (#359 **D1**).
  ///
  /// Best-effort in the same spirit as [_removeRecord]: if the sink cannot
  /// take the update, the record simply keeps its old count and is retried
  /// again next drain. Note what that costs — `lastAttemptAt` fails to
  /// persist alongside `retryCount`, so the record also loses its cooldown
  /// and is re-sent on the very next trigger. An unhealthy sink therefore
  /// trades the bound for hammering; the alternative, aborting a drain that
  /// is otherwise delivering reports, is worse. Losing a count is a smaller fault than aborting a
  /// drain that is otherwise making progress.
  ///
  /// Re-persisting rewrites the record under the same storage key. That
  /// restamps its file mtime on `FileFeedbackSink`, which is precisely why
  /// eviction keys on [QueuedFeedbackReport.queuedAt] instead.
  ///
  /// Returns the counted record once the new count is **durable**, and null
  /// when it is not — either because the record was un-addressable or
  /// because the sink refused the write. The caller uses that to decide
  /// revival, so null is the honest answer in both cases: nothing was
  /// written, so there is no exhaustion to lift.
  Future<QueuedFeedbackReport?> _countFailedAttempt(
    QueuedFeedbackReport record,
    FeedbackUnverifiedDeliveryException error,
  ) async {
    if (record.storageKey == null || record.storageKey!.isEmpty) {
      // Un-addressable, so the sink would reject the write and the count
      // could never stick — the record would re-POST on every drain
      // forever. `pending()` is contracted to discard these, so this is
      // belt-and-braces, matching [_removeRecord]'s guard.
      _logger.warn(
        'Skipping retry bookkeeping for an un-addressable queued report',
        error: error,
      );
      return null;
    }
    final counted = record.copyWith(
      retryCount: record.retryCount + 1,
      lastError: error.message,
      lastAttemptAt: _now().toUtc(),
    );
    try {
      await _sink.persist(counted);
    } on Object catch (sinkError, stackTrace) {
      _logger.warn(
        'Failed to record a feedback send attempt',
        error: sinkError,
        stackTrace: stackTrace,
        context: {'clientRequestId': record.storageKey},
      );
      return null;
    }
    // Logged only once the count is durable. Announcing exhaustion before
    // the write would have the log assert a state the next drain disagrees
    // with, on exactly the runs where the write failed.
    if (counted.isExhausted) {
      _logger.warn(
        'Queued feedback report reached its retry bound; it will be kept '
        'but no longer retried until a send on this transport succeeds',
        error: error,
        context: {
          'clientRequestId': record.storageKey,
          'retryCount': counted.retryCount,
          'statusCode': error.statusCode,
        },
      );
    }
    return counted;
  }

  /// Removes a drained record, best-effort. A record with no storage key
  /// has no address (durable sinks discard these rather than emitting
  /// them from pending(), per the [FeedbackSink] contract); any other
  /// removal fault — an unusable key reaching a strict sink, a transient
  /// I/O error — is logged and swallowed rather than allowed to abort the
  /// drain: the record simply re-sends on the next drain, and
  /// `clientRequestId` idempotency dedupes it server-side.
  Future<void> _removeRecord(QueuedFeedbackReport record) async {
    final key = record.storageKey;
    if (key == null || key.isEmpty) return;
    try {
      await _sink.remove(key);
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Failed to remove drained feedback report',
        error: error,
        stackTrace: stackTrace,
        context: {'clientRequestId': key},
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
        QueuedFeedbackReport(
          report: report,
          serverId: serverId,
          // Stamped once, here, and never rewritten — the sink's cap evicts
          // by it, and a retry-count bump must not make a record look young
          // (#359 **D1**).
          queuedAt: _now().toUtc(),
        ),
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
