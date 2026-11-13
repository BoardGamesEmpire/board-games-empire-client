import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/game/content_type.dart';
import 'package:models/src/domain/game/game_medium.dart';
import 'package:models/src/domain/game/platform_type.dart';

part 'offered_game.freezed.dart';

/// One game an attendee has offered from their collection for an event: the
/// event's games pool is every attendee's offered games (#516).
///
/// It holds what the pool shows of the game and filters it by (#851), and no
/// more. Of the owner's collection entry it holds the id and the medium: their
/// rating, comment and play counts are theirs, not the event's.
@freezed
abstract class OfferedGame with _$OfferedGame {
  const factory OfferedGame({
    /// The offered entry's own id, which a nomination's `suppliedFromId`
    /// names, and which taking the game back sends.
    required String id,

    /// The roster row of the attendee who brings the game.
    required String attendeeId,

    /// The owner's collection entry the game was offered from.
    required String collectionId,
    required String platformGameId,
    required String gameId,
    required String title,

    /// The name of the platform the owner has the game on.
    required String platformName,

    /// The game's subtitle, or null when it has none.
    String? subtitle,

    /// What kind of platform the owner has the game on. Null when the row
    /// carried none. [PlatformType.unknown] is a type this client cannot read.
    PlatformType? platformType,

    /// The owner's platform game's own picture when it has one, otherwise the
    /// game's: each one's thumbnail, else its full image (#709). Null when
    /// none of the four is set.
    String? thumbnail,

    /// Whether the owner's copy is physical or digital. Null when the row
    /// carried no medium, or one this client doesn't know.
    GameMedium? medium,

    /// What the game is. Null when the row carried none.
    /// [ContentType.unknown] is the server's own unknown, or a kind this
    /// client cannot read.
    ContentType? contentType,

    /// The year the game was published, or null when the server has none.
    int? publishYear,

    /// The players the owner's platform game takes, as a pair: the platform
    /// game's own two when either is set, otherwise the game's two. A null
    /// side means the server has no value for it.
    int? minPlayers,
    int? maxPlayers,

    /// The play time in minutes, resolved as a pair the way the players are.
    int? minPlayTime,
    int? maxPlayTime,

    /// How many open nominations name this entry as their supplier. Null when
    /// the viewer can't read nominations: none they can see is not none.
    int? suppliedNominations,

    /// How many of the event's lineup games still ahead this entry supplies.
    /// Null when the viewer can't read the lineup.
    int? suppliedLineup,
  }) = _OfferedGame;
}
