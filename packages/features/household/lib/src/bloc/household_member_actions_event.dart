import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Input to the role changes and removals on a household screen (#480).
sealed class HouseholdMemberActionsEvent extends Equatable {
  const HouseholdMemberActionsEvent();

  @override
  List<Object?> get props => [];
}

/// Give [member] the role [role].
final class HouseholdMemberRoleChangeRequested
    extends HouseholdMemberActionsEvent {
  const HouseholdMemberRoleChangeRequested(this.member, this.role);

  final HouseholdMember member;
  final HouseholdRole role;

  @override
  List<Object?> get props => [member, role];
}

/// Take [member] out of the household.
final class HouseholdMemberRemovalRequested
    extends HouseholdMemberActionsEvent {
  const HouseholdMemberRemovalRequested(this.member);

  final HouseholdMember member;

  @override
  List<Object?> get props => [member];
}

/// The person closed the last action's banner.
final class HouseholdMemberOutcomeDismissed
    extends HouseholdMemberActionsEvent {
  const HouseholdMemberOutcomeDismissed();
}
