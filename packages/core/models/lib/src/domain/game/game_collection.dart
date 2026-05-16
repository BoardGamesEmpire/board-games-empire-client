import 'package:freezed_annotation/freezed_annotation.dart';
import 'game_medium.dart';

part 'game_collection.freezed.dart';
part 'game_collection.g.dart';

/// A user's ownership record for a specific [PlatformGame].
///
/// The primary offline-capable entity. Create/update/delete operations
/// are written locally immediately and enqueued for server sync.
///
/// Soft delete: [deletedAt] is the canonical tombstone marker. A row
/// with `deletedAt != null` is awaiting remote confirmation before
/// being purged. UI consumers should treat tombstoned rows as removed.
@freezed
abstract class GameCollection with _$GameCollection {
  const GameCollection._();

  const factory GameCollection({
    required String id,
    required String userId,
    required String platformGameId,
    required GameMedium medium,

    /// Optional link to a specific [GameRelease] (printing/edition).
    String? releaseId,

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

    /// Soft-delete timestamp. Non-null means tombstoned awaiting purge.
    DateTime? deletedAt,

    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _GameCollection;

  factory GameCollection.fromJson(Map<String, dynamic> json) =>
      _$GameCollectionFromJson(json);

  /// True when the entry is live (not tombstoned) and the user owns at
  /// least one copy. UI lists should filter on this for ownership state.
  bool get isOwned => !isDeleted && quantity > 0;

  bool get hasFavorited => favorite == true;

  /// True iff [deletedAt] is set (tombstoned).
  bool get isDeleted => deletedAt != null;
}
