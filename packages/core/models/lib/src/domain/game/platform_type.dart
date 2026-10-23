/// What kind of platform a game is played on (#42).
///
/// Mirrors the backend's `PlatformType` enum (`prisma/models/game/platform.prisma`
/// in `board-games-empire-backend`). A search can be narrowed by it, and every
/// search result names it for each platform the game is on.
///
/// [fromWire] reads the stored names only. A search result from a DataGateway
/// sends the proto names instead (backend#662), and the games remote
/// translates those before they reach this type.
enum PlatformType {
  tabletop,
  console,
  portable,
  pc,
  mobile,
  arcade,
  other,

  /// A name this client does not know. Shown, never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole result.
  static PlatformType fromWire(String name) => switch (name) {
    'Tabletop' => PlatformType.tabletop,
    'Console' => PlatformType.console,
    'Portable' => PlatformType.portable,
    'PC' => PlatformType.pc,
    'Mobile' => PlatformType.mobile,
    'Arcade' => PlatformType.arcade,
    'Other' => PlatformType.other,
    _ => PlatformType.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    PlatformType.tabletop => 'Tabletop',
    PlatformType.console => 'Console',
    PlatformType.portable => 'Portable',
    PlatformType.pc => 'PC',
    PlatformType.mobile => 'Mobile',
    PlatformType.arcade => 'Arcade',
    PlatformType.other => 'Other',
    PlatformType.unknown => throw StateError(
      'PlatformType.unknown has no wire name',
    ),
  };
}
