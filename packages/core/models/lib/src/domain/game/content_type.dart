import 'package:freezed_annotation/freezed_annotation.dart';

/// Describes what a [Game] record represents.
///
/// Wire format mirrors the server `ContentType` enum (PascalCase) via
/// `@JsonValue` annotations — used by `json_serializable` for
/// freezed-class JSON round-trips.
///
/// The static [fromJson] / instance [toJson] helpers exist for direct
/// String<->enum conversion in the storage layer (Drift columns hold
/// these as strings). They must agree with the `@JsonValue` mappings;
/// a test in `content_type_test.dart` guards against drift.
///
/// See: `prisma/models/game/content-type.prisma` in
/// `board-games-empire-backend`.
enum ContentType {
  @JsonValue('Accessory')
  accessory,
  @JsonValue('BaseGame')
  baseGame,
  @JsonValue('Bundle')
  bundle,
  @JsonValue('DLC')
  dlc,
  @JsonValue('ExpandedEdition')
  expandedEdition,
  @JsonValue('Expansion')
  expansion,
  @JsonValue('Mod')
  mod,
  @JsonValue('Port')
  port,
  @JsonValue('Remake')
  remake,
  @JsonValue('Remaster')
  remaster,
  @JsonValue('StandaloneExpansion')
  standaloneExpansion,
  @JsonValue('Unknown')
  unknown;

  static ContentType fromJson(String value) => switch (value) {
    'Accessory' => accessory,
    'BaseGame' => baseGame,
    'Bundle' => bundle,
    'DLC' => dlc,
    'ExpandedEdition' => expandedEdition,
    'Expansion' => expansion,
    'Mod' => mod,
    'Port' => port,
    'Remake' => remake,
    'Remaster' => remaster,
    'StandaloneExpansion' => standaloneExpansion,
    _ => unknown,
  };

  String toJson() => switch (this) {
    accessory => 'Accessory',
    baseGame => 'BaseGame',
    bundle => 'Bundle',
    dlc => 'DLC',
    expandedEdition => 'ExpandedEdition',
    expansion => 'Expansion',
    mod => 'Mod',
    port => 'Port',
    remake => 'Remake',
    remaster => 'Remaster',
    standaloneExpansion => 'StandaloneExpansion',
    unknown => 'Unknown',
  };
}
