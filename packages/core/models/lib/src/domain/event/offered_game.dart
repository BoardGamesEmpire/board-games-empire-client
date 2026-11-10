import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/game/game_medium.dart';

part 'offered_game.freezed.dart';

/// One game an attendee has offered from their collection for an event: the
/// event's games pool is every attendee's offered games (#516).
///
/// It holds what the pool shows of the game and no more. The server serves the
/// owner's collection row whole, their rating, comment and play counts
/// included, and none of that is read into here: it is the owner's, not the
/// event's.
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

    /// The game's image, or null when it has none.
    String? thumbnail,

    /// Whether the owner's copy is physical or digital. Null when the row
    /// carried no medium, or one this client doesn't know.
    GameMedium? medium,

    /// Null when the server did not say, as an offer's answer never does.
    int? minPlayers,

    /// Null when the server did not say, as an offer's answer never does.
    int? maxPlayers,

    /// In minutes. Null when the server did not say, as an offer's answer
    /// never does.
    int? minPlayTime,

    /// In minutes. Null when the server did not say, as an offer's answer
    /// never does.
    int? maxPlayTime,
  }) = _OfferedGame;
}
