import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

import '../sync/household_hydration_status.dart';

/// Events of `HouseholdDetailBloc`.
///
/// As on the list (#269 D6), mostly *not* user events: the screen shows
/// what its sources say, and these exist so the bloc's stream
/// subscriptions have somewhere to land that can emit. The exception is
/// [HouseholdDetailRetryRequested] (#300 D10).
sealed class HouseholdDetailEvent extends Equatable {
  const HouseholdDetailEvent();

  @override
  List<Object?> get props => [];
}

/// The household cache emitted: every household readable to the current
/// user. The bloc picks its own out only once it has checked whether a
/// reconcile moved it to a new id (#306), which is why the whole list
/// travels rather than a pre-filtered row.
final class HouseholdDetailHouseholdsUpdated extends HouseholdDetailEvent {
  const HouseholdDetailHouseholdsUpdated(this.households);

  final List<Household> households;

  @override
  List<Object?> get props => [households];
}

/// The roster for [householdId] emitted.
///
/// Carries the id it was read for because the bloc can move to a new one
/// (#306): the old roster empties as its rows move, and that emission can
/// still be queued after the bloc has switched.
final class HouseholdDetailMembersUpdated extends HouseholdDetailEvent {
  const HouseholdDetailMembersUpdated(
    this.members, {
    required this.householdId,
  });

  final List<HouseholdMember> members;
  final String householdId;

  @override
  List<Object?> get props => [members, householdId];
}

/// The current user's own member row resolved, giving the bloc the user id
/// it needs to find itself in the roster (#270 D4). [userId] is null when
/// the row could not be read — the screen renders without a role rather
/// than not at all.
final class HouseholdDetailIdentityResolved extends HouseholdDetailEvent {
  const HouseholdDetailIdentityResolved(this.userId);

  final String? userId;

  @override
  List<Object?> get props => [userId];
}

/// Which of the two cache streams an event is about.
///
/// The pair are independent: they fail independently, end independently,
/// and recover independently, so every stream event names its source.
/// Collapsing them into one flag would let an emission on either stream
/// clear the other's failure.
enum HouseholdDetailSource {
  /// `watchHouseholds()`, filtered to this screen's id.
  household,

  /// `watchMembers(householdId)`.
  members,
}

/// One cache stream failed.
///
/// A roster failure carries [householdId] for the reason
/// [HouseholdDetailMembersUpdated] does (#306); it is null for the
/// household stream, which does not change when the id does.
final class HouseholdDetailReadFailed extends HouseholdDetailEvent {
  const HouseholdDetailReadFailed(this.source, {this.householdId});

  final HouseholdDetailSource source;
  final String? householdId;

  @override
  List<Object?> get props => [source, householdId];
}

/// One cache stream ended — how a user-session teardown arrives, since
/// `WatchDisposal` closes vended streams rather than erroring them.
///
/// [householdId] as on [HouseholdDetailReadFailed].
final class HouseholdDetailReadEnded extends HouseholdDetailEvent {
  const HouseholdDetailReadEnded(this.source, {this.householdId});

  final HouseholdDetailSource source;
  final String? householdId;

  @override
  List<Object?> get props => [source, householdId];
}

/// The hydration status stream ended, so no pass will ever report again.
/// A status left at `running` by a closed stream would otherwise hold an
/// absent household on the loading state forever.
final class HouseholdDetailHydrationEnded extends HouseholdDetailEvent {
  const HouseholdDetailHydrationEnded();
}

/// The hydrate reported a change (#269 D1).
final class HouseholdDetailHydrationUpdated extends HouseholdDetailEvent {
  const HouseholdDetailHydrationUpdated(this.hydration);

  final HouseholdHydrationState hydration;

  @override
  List<Object?> get props => [hydration];
}

/// The user asked for another hydrate pass (#300 D5, D10).
///
/// The same event the list carries, on the screen that shares its banner
/// and its status. A pass started by a #302 trigger arrives on
/// [HouseholdDetailHydrationUpdated] instead and is not narrated.
final class HouseholdDetailRetryRequested extends HouseholdDetailEvent {
  const HouseholdDetailRetryRequested();
}
