import 'dart:convert';

/// Sealed hierarchy of operations the sync queue can process.
///
/// Each variant carries exactly the data needed to reconstruct the server
/// request without reading from any other local table. Serialised to JSON
/// and stored in the [SyncQueueEntry.payload] column.
sealed class SyncOperation {
  const SyncOperation();

  factory SyncOperation.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String;
    return switch (type) {
      AddToCollectionOperation.type => AddToCollectionOperation.fromJson(json),
      UpdateCollectionOperation.type => UpdateCollectionOperation.fromJson(
        json,
      ),
      RemoveFromCollectionOperation.type =>
        RemoveFromCollectionOperation.fromJson(json),
      _ => throw FormatException('Unknown SyncOperation type: "$type"'),
    };
  }

  Map<String, dynamic> toJson();

  String get serialized => jsonEncode(toJson());

  static SyncOperation deserialize(String payload) =>
      SyncOperation.fromJson(jsonDecode(payload) as Map<String, dynamic>);
}

// ── GameCollection operations ────────────────────────────────────────

final class AddToCollectionOperation extends SyncOperation {
  const AddToCollectionOperation({
    required this.localId,
    required this.platformGameId,
    required this.medium,
    required this.quantity,
    this.rating,
    this.comment,
  });

  static const String type = 'add_to_collection';

  factory AddToCollectionOperation.fromJson(Map<String, dynamic> json) =>
      AddToCollectionOperation(
        localId: json['local_id'] as String,
        platformGameId: json['platform_game_id'] as String,
        medium: json['medium'] as String,
        quantity: json['quantity'] as int,
        rating: json['rating'] as int?,
        comment: json['comment'] as String?,
      );

  /// The local id of the [GameCollection] row this op writes. Generated
  /// by `GameCollectionRepositoryImpl.addToCollection` as a UUID v4 via
  /// `package:uuid` **before** the insert, so it's present on both the
  /// local row and the enqueued op. The server uses it during
  /// reconciliation: when the server's response comes back with the
  /// canonical id, `reconcileFromServer` looks up the local row by
  /// `(userId, platformGameId, medium)` triplet and drops/upserts it
  /// against the server id (see `GameCollectionRepositoryImpl` class
  /// doc for the full flow).
  ///
  /// Note: Drift does **not** generate this id — the column is a
  /// `TEXT PRIMARY KEY` whose value the repo supplies on insert.
  final String localId;
  final String platformGameId;
  final String medium;
  final int quantity;
  final int? rating;
  final String? comment;

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'local_id': localId,
    'platform_game_id': platformGameId,
    'medium': medium,
    'quantity': quantity,
    if (rating != null) 'rating': rating,
    if (comment != null) 'comment': comment,
  };
}

final class UpdateCollectionOperation extends SyncOperation {
  const UpdateCollectionOperation({
    required this.collectionId,
    this.quantity,
    this.rating,
    this.playCount,
    this.playAgain,
    this.favorite,
    this.comment,
    this.lastPlayed,
  });

  static const String type = 'update_collection';

  factory UpdateCollectionOperation.fromJson(Map<String, dynamic> json) =>
      UpdateCollectionOperation(
        collectionId: json['collection_id'] as String,
        quantity: json['quantity'] as int?,
        rating: json['rating'] as int?,
        playCount: json['play_count'] as int?,
        playAgain: json['play_again'] as bool?,
        favorite: json['favorite'] as bool?,
        comment: json['comment'] as String?,
        lastPlayed: json['last_played'] != null
            ? DateTime.parse(json['last_played'] as String)
            : null,
      );

  final String collectionId;
  final int? quantity;
  final int? rating;
  final int? playCount;
  final bool? playAgain;
  final bool? favorite;
  final String? comment;
  final DateTime? lastPlayed;

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'collection_id': collectionId,
    if (quantity != null) 'quantity': quantity,
    if (rating != null) 'rating': rating,
    if (playCount != null) 'play_count': playCount,
    if (playAgain != null) 'play_again': playAgain,
    if (favorite != null) 'favorite': favorite,
    if (comment != null) 'comment': comment,
    if (lastPlayed != null)
      'last_played': lastPlayed!.toUtc().toIso8601String(),
  };
}

final class RemoveFromCollectionOperation extends SyncOperation {
  const RemoveFromCollectionOperation({required this.collectionId});

  static const String type = 'remove_from_collection';

  factory RemoveFromCollectionOperation.fromJson(Map<String, dynamic> json) =>
      RemoveFromCollectionOperation(
        collectionId: json['collection_id'] as String,
      );

  final String collectionId;

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'collection_id': collectionId,
  };
}
