import 'package:equatable/equatable.dart';

import 'package:household/src/members/send_member_request.dart';

/// Where a request to leave a household stands (#479).
enum LeavePhase {
  /// Nothing on its way.
  idle,

  /// The request is on its way.
  sending,

  /// The server said yes. The screen is held from leaving until the cache
  /// write is done.
  leaving,

  /// The cache is written and the household is gone from the person's list.
  left,
}

/// A request to leave one household (#479).
final class LeaveHouseholdState extends Equatable {
  const LeaveHouseholdState({this.phase = LeavePhase.idle, this.failure});

  final LeavePhase phase;

  /// How the last request failed, until dismissed or replaced. Its result is
  /// gone, refused or failed; the screen words it from its error.
  final MemberRequestOutcome? failure;

  /// A request is on its way or being cached.
  bool get busy => phase == LeavePhase.sending || phase == LeavePhase.leaving;

  /// The server has said yes.
  bool get accepted => phase == LeavePhase.leaving || phase == LeavePhase.left;

  @override
  List<Object?> get props => [phase, failure];
}
