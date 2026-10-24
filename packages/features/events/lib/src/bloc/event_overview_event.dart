import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

import '../sync/event_hydration_status.dart';

/// Events of `EventOverviewBloc`.
///
/// Mostly not user events: the overview shows what three streams say, and
/// these are how the bloc's subscriptions reach its handlers. The exception
/// is [EventOverviewRetryRequested].
sealed class EventOverviewEvent extends Equatable {
  const EventOverviewEvent();

  @override
  List<Object?> get props => [];
}

/// The cache emitted a new list.
final class EventOverviewCacheUpdated extends EventOverviewEvent {
  const EventOverviewCacheUpdated(this.items);

  final List<EventListItem> items;

  @override
  List<Object?> get props => [items];
}

/// The cache stream failed.
final class EventOverviewCacheFailed extends EventOverviewEvent {
  const EventOverviewCacheFailed();
}

/// The cache stream ended: how a user-session teardown arrives, since
/// `WatchDisposal` closes vended streams rather than erroring them.
final class EventOverviewCacheEnded extends EventOverviewEvent {
  const EventOverviewCacheEnded();
}

/// The cached households changed, so the names the rows show may have.
final class EventOverviewHouseholdsUpdated extends EventOverviewEvent {
  const EventOverviewHouseholdsUpdated(this.households);

  final List<Household> households;

  @override
  List<Object?> get props => [households];
}

/// The hydrate reported a change.
final class EventOverviewHydrationUpdated extends EventOverviewEvent {
  const EventOverviewHydrationUpdated(this.hydration);

  final EventHydration hydration;

  @override
  List<Object?> get props => [hydration];
}

/// A shown date may have ended: time to group the same rows again.
final class EventOverviewClockTicked extends EventOverviewEvent {
  const EventOverviewClockTicked();
}

/// The user asked for another hydrate pass.
///
/// Distinct from a pass arriving on [EventOverviewHydrationUpdated]: this
/// one was asked for, which is what lets the screen narrate it.
final class EventOverviewRetryRequested extends EventOverviewEvent {
  const EventOverviewRetryRequested();
}
