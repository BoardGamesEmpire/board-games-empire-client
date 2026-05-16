import 'package:freezed_annotation/freezed_annotation.dart';

/// Distinguishes physical and digital copies of a game.
///
/// Wire format mirrors the server `GameMedium` enum (PascalCase) via
/// `@JsonValue` annotations. See `content_type.dart` for the dual-path
/// rationale (json_serializable vs storage layer).
///
/// See: `prisma/models/game/game-medium.prisma` in
/// `board-games-empire-backend`.
enum GameMedium {
  @JsonValue('Physical')
  physical,
  @JsonValue('Digital')
  digital;

  static GameMedium fromJson(String value) => switch (value) {
    'Physical' => physical,
    'Digital' => digital,
    _ => throw FormatException('Unknown GameMedium: $value'),
  };

  String toJson() => switch (this) {
    physical => 'Physical',
    digital => 'Digital',
  };
}
