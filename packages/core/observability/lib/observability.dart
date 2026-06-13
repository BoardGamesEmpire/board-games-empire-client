/// Observability foundation for Board Games Empire (issue #8):
/// five-level logging over `package:logging`, shared PII redaction,
/// breadcrumb capture, and the feedback-report domain mirroring the
/// backend's FeedbackReport contract.
library;

export 'src/breadcrumbs/breadcrumb.dart';
export 'src/breadcrumbs/breadcrumb_buffer.dart';
export 'src/feedback/feedback_category.dart';
export 'src/feedback/feedback_constants.dart';
export 'src/feedback/feedback_context.dart';
export 'src/feedback/feedback_report.dart';
export 'src/feedback/feedback_report_preview.dart';
export 'src/feedback/feedback_service.dart';
export 'src/feedback/feedback_severity.dart';
export 'src/logging/bge_log_level.dart';
export 'src/logging/bge_logger.dart';
export 'src/logging/context_log_message.dart';
export 'src/redaction/redaction.dart';
