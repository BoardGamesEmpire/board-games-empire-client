import 'package:json_annotation/json_annotation.dart';

/// Client- vs server-side scope of a feedback report. Drives sink
/// routing on the backend once external drivers exist.
///
/// Wire format and strictness rationale as for `FeedbackCategory`.
///
/// See: `prisma/models/feedback/feedback-report.prisma` in
/// `board-games-empire-backend`.
enum FeedbackContext {
  @JsonValue('Client')
  client,
  @JsonValue('Server')
  server,
  @JsonValue('Unknown')
  unknown;

  /// Parses a wire-format string. Strict — see class doc.
  static FeedbackContext fromWire(String value) => switch (value) {
    'Client' => client,
    'Server' => server,
    'Unknown' => unknown,
    _ => throw StateError('Unknown FeedbackContext wire value: $value'),
  };

  /// The wire-format string for this context.
  String toWire() => switch (this) {
    client => 'Client',
    server => 'Server',
    unknown => 'Unknown',
  };
}
