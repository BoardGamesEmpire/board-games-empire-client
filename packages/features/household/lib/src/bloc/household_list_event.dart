import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

import '../sync/household_hydration_status.dart';

/// Events of `HouseholdListBloc`.
///
/// Mostly *not* user events: the screen shows what two streams say, and
/// these exist because a bloc's stream subscriptions have to land
/// somewhere its handlers can emit from. The exception is
/// [HouseholdListRetryRequested] (#300) — creating is still a route push,
/// but retrying a refresh is an action on this screen's own data.
sealed class HouseholdListEvent extends Equatable {
  const HouseholdListEvent();

  @override
  List<Object?> get props => [];
}

/// The cache emitted a new list.
final class HouseholdListCacheUpdated extends HouseholdListEvent {
  const HouseholdListCacheUpdated(this.households);

  final List<Household> households;

  @override
  List<Object?> get props => [households];
}

/// The cache stream failed — see [HouseholdListError].
final class HouseholdListCacheFailed extends HouseholdListEvent {
  const HouseholdListCacheFailed();
}

/// The cache stream ended.
///
/// This is how a user-session teardown arrives: `WatchDisposal` closes
/// every vended watch stream on dispose, so subscribers see `onDone` and
/// never an error. Distinct from [HouseholdListCacheFailed] because what
/// it means depends on whether anything was read first.
final class HouseholdListCacheEnded extends HouseholdListEvent {
  const HouseholdListCacheEnded();
}

/// The hydrate reported a change (#269 D1).
final class HouseholdListHydrationUpdated extends HouseholdListEvent {
  const HouseholdListHydrationUpdated(this.hydration);

  final HouseholdHydrationState hydration;

  @override
  List<Object?> get props => [hydration];
}

/// The user asked for another hydrate pass (#300 D5).
///
/// Distinct from a pass arriving on [HouseholdListHydrationUpdated]: this
/// one was asked for, which is what licenses the screen to narrate it
/// (#300 D6). A pass started by a #302 trigger reports through the status
/// stream like any other and is not announced.
final class HouseholdListRetryRequested extends HouseholdListEvent {
  const HouseholdListRetryRequested();
}
