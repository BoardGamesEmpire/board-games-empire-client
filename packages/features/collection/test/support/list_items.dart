import 'package:models/domain.dart';

/// One collection row, with whatever a test needs set and the rest at their
/// defaults.
GameCollectionListItem listItem(
  String id, {
  String title = 'Catan',
  String? subtitle,
  String platformName = 'Board game',
  String? thumbnail,
  GameMedium medium = GameMedium.physical,
  int quantity = 1,
  int? rating,
  bool? favorite,
  DateTime? lastPlayed,
}) => GameCollectionListItem(
  entry: GameCollection(
    id: id,
    userId: 'user-1',
    platformGameId: 'pg-$id',
    medium: medium,
    quantity: quantity,
    rating: rating,
    favorite: favorite,
    lastPlayed: lastPlayed,
    createdAt: DateTime.utc(2026),
    updatedAt: DateTime.utc(2026),
  ),
  title: title,
  subtitle: subtitle,
  platformName: platformName,
  thumbnail: thumbnail,
);
