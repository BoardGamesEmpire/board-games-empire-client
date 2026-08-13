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
      CreateHouseholdOperation.type => CreateHouseholdOperation.fromJson(json),
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
  /// by `GameCollectionRepositoryImpl.addToCollection` as a cuid2 id
  /// (via `package:cuid2`) **before** the insert, so it's present on
  /// both the local row and the enqueued op.
  ///
  /// The format matches the backend's id format (cuid2). When the
  /// backend honours the client-supplied id, this id round-trips
  /// unchanged through reconciliation. Today the backend's create
  /// DTO strips ids before reaching Prisma, so the server returns a
  /// freshly-generated cuid2 instead; `reconcileFromServer` then
  /// looks up the local row by `(userId, platformGameId, medium)`
  /// triplet, calls `SyncQueueRepository.remapCollectionId` to
  /// rewrite any other pending ops still referencing this local id,
  /// and drops/upserts the row against the server's id (see
  /// `GameCollectionRepositoryImpl` class doc for the full flow).
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

// ── Household operations ─────────────────────────────────────────────

/// Creates a household on the server (`POST /api/households`).
///
/// Enqueued by `HouseholdRepositoryImpl.create` after the optimistic
/// local household row is written. Carries the full backend create
/// contract; only [localId] is client-internal (it is **not** sent to
/// the server — the remote data source builds the request body from
/// the remaining fields).
///
/// ## Why [localId] is essential here
///
/// Unlike the collection ops — which can correlate a server response
/// back to the local row via the `(userId, platformGameId, medium)`
/// business key — a household has no natural unique key (two households
/// may share a name). [localId] is therefore the only handle that ties
/// the server's response to the optimistic row it confirms. The repo
/// generates it as a cuid2 id before the insert, stores it as the local
/// row's primary key, and reconciles the server-assigned id against it
/// (the create DTO has no id field, so the server always assigns one).
final class CreateHouseholdOperation extends SyncOperation {
  const CreateHouseholdOperation({
    required this.localId,
    required this.name,
    this.description,
    this.image,
    this.language,
    this.visibility,
  });

  static const String type = 'create_household';

  factory CreateHouseholdOperation.fromJson(Map<String, dynamic> json) =>
      CreateHouseholdOperation(
        localId: json['local_id'] as String,
        name: json['name'] as String,
        description: json['description'] as String?,
        image: json['image'] as String?,
        language: json['language'] as String?,
        visibility: json['visibility'] as String?,
      );

  /// Local cuid2 id of the optimistic [Household] row this op creates.
  /// Client-internal; not part of the server request body.
  final String localId;

  final String name;
  final String? description;
  final String? image;

  /// IETF BCP 47 language tag (e.g. `en`, `pt-BR`, `zh-Hant`). The server
  /// canonicalises it and resolves it to a `LanguageTag`. `null` omits it.
  /// Deferred from the alpha create UI (#123) but carried here so that
  /// wiring it up later needs no change to the sync payload format.
  final String? language;

  /// Household visibility enum name (`Private` | `Friends`). Carried as a
  /// raw string — matching how [AddToCollectionOperation.medium] carries
  /// its enum — to avoid a premature client-side `Visibility` enum. `null`
  /// lets the server apply its default. Deferred from the alpha UI (#123).
  final String? visibility;

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'local_id': localId,
    'name': name,
    if (description != null) 'description': description,
    if (image != null) 'image': image,
    if (language != null) 'language': language,
    if (visibility != null) 'visibility': visibility,
  };
}
