import 'package:freezed_annotation/freezed_annotation.dart';
import 'game_medium.dart';

part 'game_collection.freezed.dart';
part 'game_collection.g.dart';

/// A user's ownership record for a specific [PlatformGame].
///
/// The primary offline-capable entity. Create/update/delete operations
/// are written locally immediately and enqueued for server sync.
@freezed
abstract class GameCollection with _$GameCollection {
  const GameCollection._();

  const factory GameCollection({
    required String id,
    required String userId,
    required String platformGameId,
    required GameMedium medium,

    @Default(1) int quantity,
    int? rating,
    int? playCount,
    bool? playAgain,
    bool? favorite,
    String? comment,
    DateTime? lastPlayed,
    DateTime? lastUpdated,

    /// True when this entry has local changes not yet synced to the server.
    @Default(false) bool isDirty,

    /// True when this entry was created offline and not yet confirmed by server.
    @Default(false) bool isLocalOnly,

    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _GameCollection;

  factory GameCollection.fromJson(Map<String, dynamic> json) =>
      _$GameCollectionFromJson(json);

  bool get isOwned => quantity > 0;
  bool get hasFavorited => favorite == true;
}
