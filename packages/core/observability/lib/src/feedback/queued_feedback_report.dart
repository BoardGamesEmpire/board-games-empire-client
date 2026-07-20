import 'package:freezed_annotation/freezed_annotation.dart';

import 'feedback_report.dart';

part 'queued_feedback_report.freezed.dart';
part 'queued_feedback_report.g.dart';

/// A [FeedbackReport] persisted to the durable sink, tagged with the
/// server it was approved for (#97).
///
/// The tag is client bookkeeping and deliberately lives on this envelope
/// rather than on [FeedbackReport] itself: the report mirrors the
/// backend's `CreateFeedbackReportDto` and is what the transport POSTs
/// verbatim — a client-only field there would leak into the wire payload.
///
/// [serverId] is the **stable server-vended UUID** (`bgeServerId`, read
/// from `ActiveServer.identity.serverId`), not the client-local
/// `ServerConfig.id` — it is uniform across native and web and survives
/// remove/re-add of the same server, so queued reports are never
/// orphaned by a re-add. Null means no server was active when the user
/// approved the report (e.g. a failed-boot crash report): such
/// device-global diagnostics drain into whatever server is active at
/// drain time, while records tagged for a *different* server never do.
@freezed
abstract class QueuedFeedbackReport with _$QueuedFeedbackReport {
  const factory QueuedFeedbackReport({
    /// The user-approved report, exactly as the transport will send it.
    required FeedbackReport report,

    /// `bgeServerId` of the server the report was approved for, or null
    /// when no server was active at approval time.
    String? serverId,
  }) = _QueuedFeedbackReport;

  const QueuedFeedbackReport._();

  factory QueuedFeedbackReport.fromJson(Map<String, dynamic> json) =>
      _$QueuedFeedbackReportFromJson(json);

  /// The report's idempotency token — the sink's storage key.
  String? get correlationKey => report.correlationKey;
}
