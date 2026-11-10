import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the collection list is showing (#44).
///
/// Three states, as the household list has: *empty* is
/// [GameCollectionListReady] with an empty [GameCollectionListReady.all], so
/// "empty, and possibly stale" is one value rather than an awkward pair.
sealed class GameCollectionListState extends Equatable {
  const GameCollectionListState();

  @override
  List<Object?> get props => [];
}

/// Nothing to show yet: the cache has not emitted, or it emitted nothing
/// while a hydrate is filling it for the first time.
final class GameCollectionListLoading extends GameCollectionListState {
  const GameCollectionListLoading();
}

/// The cache's current answer, narrowed by [filter] and put in [sort]'s
/// order (#715).
///
/// [all] is every entry in the collection, in the repository's order, and
/// [items] is what is shown: `sortCollection(filterCollection(all, filter),
/// sort)`. When nothing narrows and the order is [CollectionSort.title],
/// [items] is [all] itself. So an empty list reads three ways:
///
/// - [all] empty: there genuinely are no entries. A pass has confirmed it,
///   or there is no hydrate to wait for.
/// - [all] not empty, [items] empty: the collection has entries and the
///   filter matched none of them.
/// - [items] not empty: there is a list to show.
///
/// An empty [items] alone does not mean an empty collection; that is [all]
/// being empty.
///
/// [refreshFailed] says the last pass to finish ended early, so the rows may
/// be stale. A pass starting does not clear it; one completing does.
/// [refreshing] says a pass **the user asked for** is running; passes
/// started by entry, reconnect or resume are not narrated.
final class GameCollectionListReady extends GameCollectionListState {
  const GameCollectionListReady({
    required this.items,
    required this.all,
    this.filter = const CollectionFilter(),
    this.sort = CollectionSort.title,
    this.refreshFailed = false,
    this.refreshing = false,
  });

  /// What is shown: [all], narrowed by [filter], in [sort]'s order.
  final List<GameCollectionListItem> items;

  /// Every entry, in the repository's order, whatever [filter] keeps.
  final List<GameCollectionListItem> all;

  final CollectionFilter filter;
  final CollectionSort sort;
  final bool refreshFailed;
  final bool refreshing;

  @override
  List<Object?> get props => [
    items,
    all,
    filter,
    sort,
    refreshFailed,
    refreshing,
  ];
}

/// The cache read itself failed, so there is nothing to show.
///
/// Two ways in, both while a session is ending: an unauthenticated read
/// delivered as a stream error, and a stream that closes on teardown before
/// it ever emitted.
final class GameCollectionListError extends GameCollectionListState {
  const GameCollectionListError();
}
