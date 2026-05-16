import 'package:freezed_annotation/freezed_annotation.dart';

/// Distinguishes physical and digital copies of a game.
///
/// Wire format mirrors the server `GameMedium` enum (PascalCase) via
/// `@JsonValue` annotations. See `content_type.dart` for the rationale
/// behind the [fromWire] / [toWire] naming (avoids json_serializable's
/// auto-detection of `fromJson` / `toJson` on enums).
///
/// See: `prisma/models/game/game-medium.prisma` in
/// `board-games-empire-backend`.
enum GameMedium {
  @JsonValue('Physical')
  physical,
  @JsonValue('Digital')
  digital;

  static GameMedium fromWire(String value) => switch (value) {
    'Physical' => physical,
    'Digital' => digital,
    _ => throw FormatException('Unknown GameMedium: $value'),
  };

  String toWire() => switch (this) {
    physical => 'Physical',
    digital => 'Digital',
  };
}
