import 'package:models/domain.dart';

/// What the user owns of one game, platform by platform (#708).
///
/// An entry is per platform game and medium, so a platform is owned when it
/// has an entry in either medium, and can still be added while it lacks one
/// in the other.
final class PlatformOwnership {
  const PlatformOwnership._(this._platformGames, this._entries);

  /// Sorts [entries] onto [platformGames]. An entry that is not owned, such
  /// as one awaiting removal, is left out.
  factory PlatformOwnership.of({
    required List<PlatformGame> platformGames,
    required List<GameCollection> entries,
  }) {
    final byPlatformGame = <String, List<GameCollection>>{};
    for (final entry in entries) {
      if (!entry.isOwned) continue;
      (byPlatformGame[entry.platformGameId] ??= []).add(entry);
    }
    return PlatformOwnership._(platformGames, byPlatformGame);
  }

  final List<PlatformGame> _platformGames;
  final Map<String, List<GameCollection>> _entries;

  /// The owned entries on [platformGameId], or none.
  List<GameCollection> entriesOn(String platformGameId) =>
      _entries[platformGameId] ?? const [];

  bool owns(String platformGameId) => entriesOn(platformGameId).isNotEmpty;

  /// Platform games with a free medium, in `platformGames` order.
  List<CollectionAddOption> get addOptions => [
    for (final platformGame in _platformGames)
      if (_freeMediums(platformGame.id) case final free when free.isNotEmpty)
        CollectionAddOption(platformGame: platformGame, freeMediums: free),
  ];

  Set<GameMedium> _freeMediums(String platformGameId) {
    final owned = {for (final entry in entriesOn(platformGameId)) entry.medium};
    return {
      for (final medium in GameMedium.values)
        if (!owned.contains(medium)) medium,
    };
  }
}
