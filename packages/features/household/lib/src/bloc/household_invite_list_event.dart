import 'package:equatable/equatable.dart';

import '../invites/household_invite_permissions.dart';
import 'household_invite_list_state.dart';

/// Input to the household's invite list (#455).
sealed class HouseholdInviteListEvent extends Equatable {
  const HouseholdInviteListEvent();

  @override
  List<Object?> get props => [];
}

/// Read the list again from the server. The rows on screen stay while it
/// runs.
final class HouseholdInviteListLoadRequested extends HouseholdInviteListEvent {
  const HouseholdInviteListLoadRequested();
}

/// Show [filter]'s invites instead, read afresh.
final class HouseholdInviteListFilterChanged extends HouseholdInviteListEvent {
  const HouseholdInviteListFilterChanged(this.filter);

  final HouseholdInviteFilter filter;

  @override
  List<Object?> get props => [filter];
}

/// Read the next page and add it below the rows on screen.
final class HouseholdInviteListMoreRequested extends HouseholdInviteListEvent {
  const HouseholdInviteListMoreRequested();
}

/// Take [action] on the invite [inviteId].
final class HouseholdInviteListActionRequested
    extends HouseholdInviteListEvent {
  const HouseholdInviteListActionRequested(this.action, this.inviteId);

  final HouseholdInviteRowAction action;
  final String inviteId;

  @override
  List<Object?> get props => [action, inviteId];
}

/// The person closed the last action's banner.
final class HouseholdInviteListOutcomeDismissed
    extends HouseholdInviteListEvent {
  const HouseholdInviteListOutcomeDismissed();
}
