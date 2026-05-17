import 'package:freezed_annotation/freezed_annotation.dart';
import 'time_measure.dart';

part 'platform_game.freezed.dart';
part 'platform_game.g.dart';

/// Client-side cache of a BGE server [PlatformGame] record.
///
/// Nullable override fields fall back to parent [Game] values when null.
/// [platformName] is the denormalized platform name (e.g. "Tabletop", "Steam").
@freezed
abstract class PlatformGame with _$PlatformGame {
  const PlatformGame._();

  const factory PlatformGame({
    required String id,
    required String gameId,

    required String platformId,
    required String platformName,

    // Platform-specific overrides — null means use parent Game value
    int? minPlayers,
    int? maxPlayers,
    int? minPlayTime,
    TimeMeasure? minPlayTimeMeasure,
    int? maxPlayTime,
    TimeMeasure? maxPlayTimeMeasure,
    String? image,
    String? thumbnail,

    @Default(false) bool supportsSolo,
    @Default(false) bool supportsLocal,
    @Default(false) bool supportsOnline,
    @Default(false) bool hasAsyncPlay,
    @Default(false) bool hasRealtime,
    @Default(false) bool hasTutorial,

    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _PlatformGame;

  factory PlatformGame.fromJson(Map<String, dynamic> json) =>
      _$PlatformGameFromJson(json);

  /// Resolved player min, preferring platform override over [gameMinPlayers].
  int? resolvedMinPlayers(int? gameMinPlayers) => minPlayers ?? gameMinPlayers;

  /// Resolved player max, preferring platform override over [gameMaxPlayers].
  int? resolvedMaxPlayers(int? gameMaxPlayers) => maxPlayers ?? gameMaxPlayers;
}
