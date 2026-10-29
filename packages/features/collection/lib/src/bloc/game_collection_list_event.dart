import 'package:equatable/equatable.dart';
import 'package:hydration/hydration.dart';
import 'package:models/domain.dart';

/// Events of `GameCollectionListBloc`.
///
/// Mostly not user events: the list shows what two streams say, and these
/// are how the bloc's subscriptions reach its handlers. The exception is
/// [GameCollectionListRetryRequested].
sealed class GameCollectionListEvent extends Equatable {
  const GameCollectionListEvent();

  @override
  List<Object?> get props => [];
}

/// The cache emitted a new list.
final class GameCollectionListCacheUpdated extends GameCollectionListEvent {
  const GameCollectionListCacheUpdated(this.items);

  final List<GameCollectionListItem> items;

  @override
  List<Object?> get props => [items];
}

/// The cache stream failed.
final class GameCollectionListCacheFailed extends GameCollectionListEvent {
  const GameCollectionListCacheFailed();
}

/// The cache stream ended: how a user-session teardown arrives, since
/// `WatchDisposal` closes vended streams rather than erroring them.
final class GameCollectionListCacheEnded extends GameCollectionListEvent {
  const GameCollectionListCacheEnded();
}

/// The hydrate reported a change.
final class GameCollectionListHydrationUpdated extends GameCollectionListEvent {
  const GameCollectionListHydrationUpdated(this.hydration);

  final Hydration hydration;

  @override
  List<Object?> get props => [hydration];
}

/// The user asked for another hydrate pass.
///
/// Distinct from a pass arriving on [GameCollectionListHydrationUpdated]:
/// this one was asked for, which is what lets the screen narrate it.
final class GameCollectionListRetryRequested extends GameCollectionListEvent {
  const GameCollectionListRetryRequested();
}
