import 'package:freezed_annotation/freezed_annotation.dart';

part 'platform_game_summary.freezed.dart';

/// The slice of a [PlatformGame] and its parent [Game] that every server
/// collection response embeds (#259).
///
/// The server joins it onto each collection row so a list can render
/// without a second fetch. It is **not** a full record: it carries exactly
/// what `COLLECTION_INCLUDE` selects, and nothing about player counts,
/// play time or any other game metadata. The platform `slug` the wire also
/// carries is left out, because no table has a column for it and nothing
/// reads it.
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

    /// The platform game's own image override. Null means "use the game's".
    String? image,

    /// The platform game's own thumbnail override. Null means "use the
    /// game's".
    String? thumbnail,

    required GameSummary game,
  }) = _PlatformGameSummary;
}

/// The parent [Game]'s share of a [PlatformGameSummary].
@freezed
abstract class GameSummary with _$GameSummary {
  const factory GameSummary({
    required String id,
    required String title,
    String? subtitle,
    String? image,
    String? thumbnail,
  }) = _GameSummary;
}
