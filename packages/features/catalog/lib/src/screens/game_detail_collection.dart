import 'package:flutter/widgets.dart';
import 'package:models/domain.dart';

/// What the detail page can do with the user's collection (#708). All or
/// nothing: the shell builds one only where the session can write the
/// collection.
///
/// Callbacks rather than the collection's repository, because the catalog
/// does not depend on the collection feature, and the page needs to read
/// only what the user owns of this one game, not the collection's whole
/// write surface.
final class GameDetailCollection {
  const GameDetailCollection({
    required this.watchOwned,
    required this.onAdd,
    required this.onOpenOwned,
  });

  /// The user's live entries on these platform games, and again whenever
  /// they change. An entry awaiting removal counts as not owned.
  ///
  /// The page calls this once per set of platform game ids, and keeps that
  /// one stream for as long as it has a collection: a new
  /// [GameDetailCollection] with the same ids, as each build of the route
  /// hands over, is not watched again. So the stream must follow the source
  /// for as long as the page is open, and the source must not be swapped
  /// under a live page; a page whose source changes is built anew.
  final Stream<List<GameCollection>> Function(Set<String> platformGameIds)
  watchOwned;

  /// Opens the add for `game`, offering `options`: the platforms the user
  /// can still add it on, as they stood at the press. `platformGameId` is
  /// the platform chosen to start with, or null for none.
  final void Function(
    BuildContext context,
    Game game,
    List<CollectionAddOption> options, {
    String? platformGameId,
  })
  onAdd;

  /// One platform game's entries: one opens it, several open the picker.
  final void Function(BuildContext context, List<GameCollectionListItem> items)
  onOpenOwned;
}
