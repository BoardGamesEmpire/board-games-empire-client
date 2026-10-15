import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the collection list is showing (#44).
///
/// Three states, as the household list has: *empty* is
/// [GameCollectionListReady] with no rows, so "empty, and possibly stale" is
/// one value rather than an awkward pair.
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

/// The cache's current answer. [items] may be empty, which means there
/// genuinely are none: a pass has confirmed it, or there is no hydrate to
/// wait for.
///
/// [refreshFailed] says the last pass to finish ended early, so the rows may
/// be stale. A pass starting does not clear it; one completing does.
/// [refreshing] says a pass **the user asked for** is running; passes
/// started by entry, reconnect or resume are not narrated.
final class GameCollectionListReady extends GameCollectionListState {
  const GameCollectionListReady({
    required this.items,
    this.refreshFailed = false,
    this.refreshing = false,
  });

  final List<GameCollectionListItem> items;
  final bool refreshFailed;
  final bool refreshing;

  @override
  List<Object?> get props => [items, refreshFailed, refreshing];
}

/// The cache read itself failed, so there is nothing to show.
///
/// Two ways in, both while a session is ending: an unauthenticated read
/// delivered as a stream error, and a stream that closes on teardown before
/// it ever emitted.
final class GameCollectionListError extends GameCollectionListState {
  const GameCollectionListError();
}
