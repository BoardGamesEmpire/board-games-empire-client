import 'package:freezed_annotation/freezed_annotation.dart';
import '../common/visibility.dart';
import 'content_type.dart';
import 'time_measure.dart';

part 'game.freezed.dart';
part 'game.g.dart';

/// Client-side cache of a BGE server [Game] record.
///
/// Relation tables (categories, mechanics, designers etc.) are stored as
/// string lists sourced from denormalized server responses. This avoids
/// a dozen join tables in the local DB while keeping display data available.
@freezed
abstract class Game with _$Game {
  const Game._();

  const factory Game({
    required String id,
    required String title,
    String? subtitle,
    String? description,
    String? image,
    String? thumbnail,
    int? publishYear,

    // Player counts
    int? minPlayers,
    int? maxPlayers,

    // Play time
    /// Aggregate playing time in minutes (server `Game.playingTime`).
    int? playingTime,
    int? minPlayTime,
    TimeMeasure? minPlayTimeMeasure,
    int? maxPlayTime,
    TimeMeasure? maxPlayTimeMeasure,
    int? minAge,

    double? complexity,
    @Default(ContentType.baseGame) ContentType contentType,

    // Aggregate metadata from server
    @Default(0) int totalPlayCount,
    double? averageRating,
    double? bayesRating,
    int? ratingsCount,
    @Default(0) int ownedByCount,

    // Denormalized relation lists — stored as JSON in local DB
    @Default(<String>[]) List<String> categories,
    @Default(<String>[]) List<String> mechanics,
    @Default(<String>[]) List<String> designers,
    @Default(<String>[]) List<String> publishers,
    @Default(<String>[]) List<String> tags,

    // Access control
    @Default(Visibility.public) Visibility visibility,
    String? createdById,

    DateTime? deletedAt,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _Game;

  factory Game.fromJson(Map<String, dynamic> json) => _$GameFromJson(json);

  /// Display-friendly player count string. e.g. "2–4" or "1–6".
  String? get playerCountDisplay {
    if (minPlayers == null && maxPlayers == null) return null;
    if (minPlayers == maxPlayers) return '$minPlayers';
    if (minPlayers == null) return 'Up to $maxPlayers';
    if (maxPlayers == null) return '$minPlayers+';
    return '$minPlayers–$maxPlayers';
  }

  bool get isDeleted => deletedAt != null;
}
