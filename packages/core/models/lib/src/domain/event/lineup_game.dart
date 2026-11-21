import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/event/scheduled_game_role.dart';

part 'lineup_game.freezed.dart';

/// One game on an event's lineup: on the event itself, or on one of its dates
/// (#519, #920).
///
/// It names the game, where it sits and who supplies it, and no more. The
/// supplier's copy is a row in the games pool, [suppliedById].
@freezed
abstract class LineupGame with _$LineupGame {
  const factory LineupGame({
    required String id,
    required String platformGameId,

    /// Read from `platformGame.game.id`.
    required String gameId,

    /// Read from `platformGame.game.title`.
    required String title,

    /// Read from `platformGame.platform.name`.
    required String platformName,
    required ScheduledGameRole role,

    /// The game's place in the host's order, within its date or the event's
    /// own games.
    required int sortOrder,

    /// The `OfferedGame.id` of the pool row the game is supplied from.
    required String suppliedById,

    /// The roster row of the attendee who brings the game.
    required String supplierAttendeeId,

    /// The date the game is on, or null for the event's own lineup.
    String? occurrenceId,

    /// Read from `platformGame.game.subtitle`; null when the game has none.
    String? subtitle,

    /// Read from `platformGame.game.thumbnail`; null when the game has none.
    String? thumbnail,

    /// A note the host left on the game.
    String? notes,

    /// The longest the game should run, for a filler; null otherwise.
    int? maxPlayTime,

    /// The nomination the game came from, or null for a game added directly.
    String? nominationId,

    /// The roster row of the attendee who added the game.
    String? addedById,

    /// The supplier's name: their display name, else their username, else the
    /// name a guest was added by. Null when the server did not serve the
    /// attendee, for a caller who cannot read them.
    String? supplierName,
  }) = _LineupGame;
}
