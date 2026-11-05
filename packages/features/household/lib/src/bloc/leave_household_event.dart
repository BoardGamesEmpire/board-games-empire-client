import 'package:equatable/equatable.dart';

/// Input to leaving a household (#479).
sealed class LeaveHouseholdEvent extends Equatable {
  const LeaveHouseholdEvent();

  @override
  List<Object?> get props => [];
}

/// Leave the household [householdId], the server's id for it.
final class LeaveHouseholdRequested extends LeaveHouseholdEvent {
  const LeaveHouseholdRequested(this.householdId);

  final String householdId;

  @override
  List<Object?> get props => [householdId];
}

/// The person closed the failure banner.
final class LeaveHouseholdFailureDismissed extends LeaveHouseholdEvent {
  const LeaveHouseholdFailureDismissed();
}
