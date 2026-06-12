import 'package:json_annotation/json_annotation.dart';

/// Severity of a feedback report. Required (backend-validated, and
/// constructor-asserted client-side on `FeedbackReport`) when the
/// category is `Bug` or `Crash`; not applicable to feature requests.
///
/// Wire format and strictness rationale as for `FeedbackCategory`.
///
/// See: `prisma/models/feedback/feedback-report.prisma` in
/// `board-games-empire-backend`.
enum FeedbackSeverity {
  @JsonValue('Low')
  low,
  @JsonValue('Medium')
  medium,
  @JsonValue('High')
  high,
  @JsonValue('Critical')
  critical;

  /// Parses a wire-format string. Strict — see class doc.
  static FeedbackSeverity fromWire(String value) => switch (value) {
    'Low' => low,
    'Medium' => medium,
    'High' => high,
    'Critical' => critical,
    _ => throw StateError('Unknown FeedbackSeverity wire value: $value'),
  };

  /// The wire-format string for this severity.
  String toWire() => switch (this) {
    low => 'Low',
    medium => 'Medium',
    high => 'High',
    critical => 'Critical',
  };
}
