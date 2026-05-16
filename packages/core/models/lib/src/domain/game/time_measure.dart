import 'package:freezed_annotation/freezed_annotation.dart';

/// Unit of measure for play duration fields on [Game] and [PlatformGame].
///
/// Wire format mirrors the server `TimeMeasure` enum (PascalCase) via
/// `@JsonValue` annotations. See `content_type.dart` for the rationale
/// behind the [fromWire] / [toWire] naming.
///
/// See: `prisma/models/enums/time-measure.prisma` in
/// `board-games-empire-backend`.
enum TimeMeasure {
  @JsonValue('Minutes')
  minutes,
  @JsonValue('Hours')
  hours,
  @JsonValue('Days')
  days,
  @JsonValue('Weeks')
  weeks,
  @JsonValue('Months')
  months,
  @JsonValue('Years')
  years;

  static TimeMeasure fromWire(String value) => switch (value) {
    'Minutes' => minutes,
    'Hours' => hours,
    'Days' => days,
    'Weeks' => weeks,
    'Months' => months,
    'Years' => years,
    _ => throw FormatException('Unknown TimeMeasure: $value'),
  };

  String toWire() => switch (this) {
    minutes => 'Minutes',
    hours => 'Hours',
    days => 'Days',
    weeks => 'Weeks',
    months => 'Months',
    years => 'Years',
  };
}
