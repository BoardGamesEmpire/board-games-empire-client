import 'package:freezed_annotation/freezed_annotation.dart';

/// Describes what a [Game] record represents.
///
/// Wire format mirrors the server `ContentType` enum (PascalCase) via
/// `@JsonValue` annotations — the sole serialization path used by
/// `json_serializable` for freezed-class JSON round-trips.
///
/// The [fromWire] / [toWire] helpers exist for direct String<->enum
/// conversion in the storage layer (Drift columns hold these as strings).
/// They MUST agree with the `@JsonValue` mappings; a test in
/// `content_type_test.dart` guards against drift.
///
/// Note: these helpers are deliberately NOT named `fromJson` / `toJson`.
/// `json_serializable` auto-detects methods with those names on enums and
/// generates ambiguous serialization code that emits the raw enum instead
/// of the wire string. Using distinct names keeps `@JsonValue` as the
/// single source of truth for the freezed JSON path.
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

  /// Parses a wire-format string back to a [ContentType]. Unknown values
  /// fall back to [ContentType.unknown] rather than throwing.
  static ContentType fromWire(String value) => switch (value) {
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

  /// PascalCase wire representation matching the server `ContentType` enum.
  String toWire() => switch (this) {
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
