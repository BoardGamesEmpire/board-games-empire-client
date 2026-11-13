import 'package:freezed_annotation/freezed_annotation.dart';

part 'game_offer_result.freezed.dart';

/// Why the server did not offer one collection entry of a batch (#851).
enum GameOfferRefusal {
  /// No collection entry has the id.
  notFound,

  /// The entry is in someone else's collection.
  notInAttendeesCollection,

  /// The entry was removed from the collection since.
  removedFromCollection,

  /// Named as an expansion, but its game is not an expansion of its base.
  notAnExpansionOfBase,

  /// Named as an expansion of a game that was refused.
  baseRefused,

  /// A reason this client does not know, or an outcome it cannot read.
  unknown;

  /// Resolves the server's refusal code, degrading to [unknown].
  static GameOfferRefusal fromWire(String value) => switch (value) {
    'notFound' => GameOfferRefusal.notFound,
    'notInAttendeesCollection' => GameOfferRefusal.notInAttendeesCollection,
    'removedFromCollection' => GameOfferRefusal.removedFromCollection,
    'notAnExpansionOfBase' => GameOfferRefusal.notAnExpansionOfBase,
    'baseRefused' => GameOfferRefusal.baseRefused,
    _ => GameOfferRefusal.unknown,
  };
}

/// What happened to one collection entry of a batch offer (#851).
@freezed
sealed class GameOfferResult with _$GameOfferResult {
  /// The entry is on the event's pool: new, offered again after a take-back,
  /// or already there.
  const factory GameOfferResult.offered({
    required String collectionId,

    /// True when the game was already offered, so nothing was added.
    required bool alreadyOffered,
  }) = GameOffered;

  /// The server did not offer the entry.
  const factory GameOfferResult.refused({
    required String collectionId,
    required GameOfferRefusal reason,

    /// The server's own text, in the caller's language. Empty when it sent
    /// none.
    required String message,
  }) = GameOfferRefused;
}
