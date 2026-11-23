import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:hydration/hydration.dart';
import 'package:models/domain.dart';

/// Events of `GameCollectionListBloc`.
///
/// Mostly not user events: the list shows what two streams say, and these
/// are how the bloc's subscriptions reach its handlers. The exceptions are
/// [GameCollectionListRetryRequested], [GameCollectionListFilterChanged] and
/// [GameCollectionListSortChanged].
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
///
/// [done] completes once the pass this request started, or the one it found
/// already running, has ended — at once where there is no pass to run. It
/// never completes with an error. A pull-to-refresh hands its Future to the
/// spinner, so the spinner ends with the pass (#717).
final class GameCollectionListRetryRequested extends GameCollectionListEvent {
  const GameCollectionListRetryRequested({this.done});

  /// Completed when the pass ends. Not part of [props]: two requests are
  /// the same request, whoever is waiting on them.
  final Completer<void>? done;
}

/// The user narrowed the list another way (#715).
final class GameCollectionListFilterChanged extends GameCollectionListEvent {
  const GameCollectionListFilterChanged(this.filter);

  final CollectionFilter filter;

  @override
  List<Object?> get props => [filter];
}

/// The user put the list in another order (#715).
final class GameCollectionListSortChanged extends GameCollectionListEvent {
  const GameCollectionListSortChanged(this.sort);

  final CollectionSort sort;

  @override
  List<Object?> get props => [sort];
}
