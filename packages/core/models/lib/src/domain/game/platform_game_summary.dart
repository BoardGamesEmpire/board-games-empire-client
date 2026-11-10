import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/game/content_type.dart';
import 'package:models/src/domain/game/expansion_link.dart';
import 'package:models/src/domain/game/platform_type.dart';

part 'platform_game_summary.freezed.dart';

/// The slice of a `PlatformGame` and its parent `Game` that every server
/// collection response embeds (#259).
///
/// The server joins it onto each collection row so a list can render
/// without a second fetch. It is **not** a full record: it carries exactly
/// what `COLLECTION_INCLUDE` selects. Besides identity, artwork and what the
/// game is, that is the facts a collection filter and sort read (#715): the
/// game's [GameSummaryFacts] on [GameSummary.facts] and this platform game's
/// own [PlatformGameSummaryFacts] on [facts]. Null [facts] means the response
/// did not carry them (an older server), so a cache write keeps what it has;
/// non-null facts with null fields mean the response says there is no value,
/// and that is written. The platform `slug` the wire also carries is left
/// out, because no table has a column for it and nothing reads it.
///
/// It lands in the local `games` / `platform_games` rows through
/// `GameRepository.cachePlatformGameSummaries`, which writes only these
/// columns, so a fuller record cached by another path keeps its other
/// fields.
@freezed
abstract class PlatformGameSummary with _$PlatformGameSummary {
  const factory PlatformGameSummary({
    required String id,
    required String platformId,
    required String platformName,

    required GameSummary game,

    /// The platform game's own image override. Null means "use the game's".
    String? image,

    /// The platform game's own thumbnail override. Null means "use the
    /// game's".
    String? thumbnail,

    /// The platform game's own facts (#715). Null means the response did not
    /// carry them, so a cache write keeps what it has.
    PlatformGameSummaryFacts? facts,
  }) = _PlatformGameSummary;
}

/// The parent `Game`'s share of a [PlatformGameSummary].
@freezed
abstract class GameSummary with _$GameSummary {
  const factory GameSummary({
    required String id,
    required String title,
    String? subtitle,
    String? image,
    String? thumbnail,

    /// What the game is (#711). Null means the response did not carry it, so
    /// a cache write keeps what it has.
    ContentType? contentType,

    /// The game's base games (#711). Null means the response did not carry
    /// them, so a cache write keeps what it has; empty means it has none.
    List<ExpansionLink>? baseGames,

    /// The game's own facts (#715). Null means the response did not carry
    /// them, so a cache write keeps what it has.
    GameSummaryFacts? facts,
  }) = _GameSummary;
}

/// The facts of a `Game` a collection filter and sort read (#715).
///
/// An object of these means the response carried them: a null field is then
/// the server saying the game has no value, which a cache write stores. A
/// response that did not carry them leaves [GameSummary.facts] null instead.
@freezed
abstract class GameSummaryFacts with _$GameSummaryFacts {
  const factory GameSummaryFacts({
    int? publishYear,
    int? minPlayers,
    int? maxPlayers,
    int? minPlayTime,
    int? maxPlayTime,
  }) = _GameSummaryFacts;
}

/// The facts of a `PlatformGame` a collection filter and sort read (#715).
///
/// An object of these means the response carried them: a null field is then
/// the server saying the platform game has no value, which a cache write
/// stores. A response that did not carry them leaves
/// [PlatformGameSummary.facts] null instead.
@freezed
abstract class PlatformGameSummaryFacts with _$PlatformGameSummaryFacts {
  const factory PlatformGameSummaryFacts({
    PlatformType? platformType,
    int? minPlayers,
    int? maxPlayers,
    int? minPlayTime,
    int? maxPlayTime,
  }) = _PlatformGameSummaryFacts;
}
