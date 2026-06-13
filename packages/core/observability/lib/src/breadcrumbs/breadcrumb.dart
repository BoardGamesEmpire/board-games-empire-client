import 'package:freezed_annotation/freezed_annotation.dart';

import '../logging/bge_log_level.dart';

part 'breadcrumb.freezed.dart';
part 'breadcrumb.g.dart';

/// A captured log record, sanitised and frozen for inclusion in a
/// feedback report (issue #8).
///
/// Produced by the BreadcrumbBuffer from `LogRecord`s; never constructed
/// from raw user input. By the time a record becomes a [Breadcrumb] its
/// [message] has been through email-pattern masking and its
/// [sanitizedContext] through key-based field redaction — PII can't sneak
/// into a buffered crumb via a forgotten `info` call.
///
/// JSON shape is client-internal (offline persistence of draft reports);
/// the backend FeedbackReport model has no breadcrumb field yet, so the
/// transport mapping is decided by the concrete FeedbackService
/// implementations (separate issue).
@freezed
abstract class Breadcrumb with _$Breadcrumb {
  const factory Breadcrumb({
    /// When the underlying record was emitted.
    required DateTime timestamp,

    /// The record's level, collapsed onto the BGE five-level scheme.
    required BgeLogLevel level,

    /// Hierarchical name of the emitting logger (e.g.
    /// `bge.storage.sync_queue`).
    required String loggerName,

    /// The log message, post email-pattern masking.
    required String message,

    /// The structured context map, post key-based redaction. Null when
    /// the record carried no context.
    Map<String, dynamic>? sanitizedContext,
  }) = _Breadcrumb;

  factory Breadcrumb.fromJson(Map<String, dynamic> json) =>
      _$BreadcrumbFromJson(json);
}
