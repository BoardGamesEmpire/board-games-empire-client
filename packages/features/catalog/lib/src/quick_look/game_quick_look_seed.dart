import 'package:flutter/foundation.dart';
import 'package:models/domain.dart';

/// What a caller already holds about a game when it opens the game's quick
/// look (#707), which shows it at once while the rest is read.
///
/// Callers hold different things. "Newest games" and the Games list hold
/// full [Game] rows, so the quick look can show the players, the play time
/// and the age before the read lands. "Something to play" holds a
/// [GameSummary], which has the title and the images and nothing more, so
/// those wait for the read.
@immutable
class GameQuickLookSeed {
  const GameQuickLookSeed({
    required this.id,
    required this.title,
    this.subtitle,
    this.image,
    this.thumbnail,
    this.game,
  });

  /// From a full row, which the quick look shows all of at once.
  factory GameQuickLookSeed.fromGame(Game game) => GameQuickLookSeed(
    id: game.id,
    title: game.title,
    subtitle: game.subtitle,
    image: game.image,
    thumbnail: game.thumbnail,
    game: game,
  );

  /// From a summary, which has no facts until the read lands.
  factory GameQuickLookSeed.fromSummary(GameSummary summary) =>
      GameQuickLookSeed(
        id: summary.id,
        title: summary.title,
        subtitle: summary.subtitle,
        image: summary.image,
        thumbnail: summary.thumbnail,
      );

  final String id;
  final String title;
  final String? subtitle;
  final String? image;
  final String? thumbnail;

  /// The whole game, when the caller has it. Null until the read lands.
  final Game? game;
}
