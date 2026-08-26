import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

import '../sync/household_hydration_status.dart';

/// Internal events of `HouseholdListBloc`.
///
/// There are no *user* events: the screen shows what two streams say, and
/// the only action on it (create) is a route push. These exist because a
/// bloc's stream subscriptions have to land somewhere its handlers can
/// emit from.
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
