import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the collection list is showing (#44).
///
/// Three states, as the household list has: *empty* is
/// [GameCollectionListReady] with an empty [GameCollectionListReady.all], so
/// "empty, and possibly stale" is one value rather than an awkward pair.
///
/// Every state carries [refreshing], whatever the list shows: the app bar's
/// refresh button reports a pass the user asked for on every surface
/// (#717).
sealed class GameCollectionListState extends Equatable {
  const GameCollectionListState({this.refreshing = false});

  /// A pass **the user asked for** is running; passes started by entry,
  /// reconnect or resume are not narrated.
  ///
  /// Only a ready state's banner narrates it. On a loading or error state
  /// it is for the refresh button's label alone, so the button says the
  /// pass it started is running where there is no banner to say so (#717).
  final bool refreshing;

  @override
  List<Object?> get props => [refreshing];
}

/// Nothing to show yet: the cache has not emitted, or it emitted nothing
/// while a hydrate is filling it for the first time.
///
/// A pass the user asked for can run here, as a retry over an unconfirmed
/// empty list comes back to the spinner (#300): [refreshing] says so to the
/// refresh button, and the spinner stays the one thing shown.
final class GameCollectionListLoading extends GameCollectionListState {
  const GameCollectionListLoading({super.refreshing});
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
/// [refreshing] says a pass **the user asked for** is running, and here the
/// banner narrates it.
final class GameCollectionListReady extends GameCollectionListState {
  const GameCollectionListReady({
    required this.items,
    required this.all,
    this.filter = const CollectionFilter(),
    this.sort = CollectionSort.title,
    this.refreshFailed = false,
    super.refreshing,
    this.complete = true,
  });

  /// What is shown: [all], narrowed by [filter], in [sort]'s order.
  final List<GameCollectionListItem> items;

  /// Every entry, in the repository's order, whatever [filter] keeps.
  final List<GameCollectionListItem> all;

  final CollectionFilter filter;
  final CollectionSort sort;
  final bool refreshFailed;

  /// False while the device's first sync runs: a pass is running, no pass
  /// has completed on this device, and none has failed in this session
  /// (#810). The pass writes the cache a page at a time, so a base game may
  /// not have landed, and the screen holds an expansion that is missing its
  /// base game rather than show it marked. A pass that fails or completes
  /// makes it true, and a retry after a failed pass leaves it true.
  ///
  /// It is the device's, not the session's (#1011): a cold start over a
  /// cache an earlier session's pass completed is true throughout its pass,
  /// so an expansion whose base game isn't owned stays shown, marked.
  final bool complete;

  @override
  List<Object?> get props => [
    items,
    all,
    filter,
    sort,
    refreshFailed,
    refreshing,
    complete,
  ];
}

/// The cache read itself failed, so there is nothing to show.
///
/// Two ways in, both while a session is ending: an unauthenticated read
/// delivered as a stream error, and a stream that closes on teardown before
/// it ever emitted.
///
/// A pass the user asked for can still run here, and fresh rows from it
/// clear a transient read failure. There is no banner over this state, so
/// [refreshing] is for the refresh button's label alone (#717).
final class GameCollectionListError extends GameCollectionListState {
  const GameCollectionListError({super.refreshing});
}
