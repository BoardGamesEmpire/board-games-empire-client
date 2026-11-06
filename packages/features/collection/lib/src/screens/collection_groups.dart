import 'package:models/domain.dart';

/// [items] gathered by game, for the collection to show a game owned more
/// than once as one stack (#709).
///
/// An entry is per platform game and medium, so one game owned on two
/// platforms, or on one platform as a physical and a digital copy, is two
/// items, and here one group. Each group sits where its game's first item
/// did, and keeps its items in the order they came: the repository orders
/// them, by title then entry id, and the screen doesn't order them again.
///
/// A step of its own over the list items, so a filter (#715) can run before
/// it and a stack is then made of the entries that matched.
List<List<GameCollectionListItem>> groupByGame(
  List<GameCollectionListItem> items,
) {
  final groups = <String, List<GameCollectionListItem>>{};
  for (final item in items) {
    (groups[item.gameId] ??= []).add(item);
  }
  return [...groups.values];
}
