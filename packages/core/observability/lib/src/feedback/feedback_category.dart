import 'package:json_annotation/json_annotation.dart';

/// What kind of report this is.
///
/// Wire format mirrors the server `FeedbackCategory` enum (PascalCase)
/// via `@JsonValue` annotations. [fromWire] / [toWire] exist for direct
/// String<->enum conversion (offline persistence); they MUST agree with
/// the `@JsonValue` mappings — `feedback_enums_test.dart` guards drift.
///
/// [fromWire] is strict: these values are client-authored, so an
/// unrecognised string indicates corruption rather than a server enum
/// extension and throws [StateError] (contrast `ContentType`'s lenient
/// fallback for server-authored payloads).
///
/// See: `prisma/models/feedback/feedback-report.prisma` in
/// `board-games-empire-backend`.
enum FeedbackCategory {
  @JsonValue('Bug')
  bug,
  @JsonValue('Crash')
  crash,
  @JsonValue('FeatureRequest')
  featureRequest;

  /// Parses a wire-format string. Strict — see class doc.
  static FeedbackCategory fromWire(String value) => switch (value) {
    'Bug' => bug,
    'Crash' => crash,
    'FeatureRequest' => featureRequest,
    _ => throw StateError('Unknown FeedbackCategory wire value: $value'),
  };

  /// The wire-format string for this category.
  String toWire() => switch (this) {
    bug => 'Bug',
    crash => 'Crash',
    featureRequest => 'FeatureRequest',
  };
}
