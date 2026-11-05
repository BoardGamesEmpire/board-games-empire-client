import 'package:equatable/equatable.dart';

import '../permissions/household_actions.dart';

/// How a member request ended: a role change, removal or ownership transfer
/// (#480, #478), or a request to leave (#479).
enum HouseholdMemberActionResult {
  /// The server did it, and its answer is cached.
  done,

  /// The server says the member is not in the household, or that the
  /// household is gone: its 404 does not say which (#122). On a removal
  /// either way they are out of it; on a role change or a transfer there is
  /// no one to change or to hand the household to. On a leave the member is
  /// the person themselves, and the refresh, not this answer, takes the
  /// household away (#479).
  gone,

  /// The server said no, with a 400, 403 or 409. The outcome's error says
  /// which.
  refused,

  /// No answer that says what happened. The outcome's error says why.
  failed,
}

/// The outcome of the last role change, removal or ownership transfer, for
/// the banner under the member count on the household screen (#480, #478).
final class HouseholdMemberOutcome extends Equatable {
  const HouseholdMemberOutcome({
    required this.action,
    required this.result,
    this.error,
  });

  final HouseholdMemberAction action;
  final HouseholdMemberActionResult result;

  /// What the action failed with, for `memberActionMessage`. Null when it
  /// was done.
  final Object? error;

  @override
  List<Object?> get props => [action, result, error];
}

/// The role changes, removals and ownership transfers on one household
/// screen (#480, #478).
final class HouseholdMemberActionsState extends Equatable {
  const HouseholdMemberActionsState({this.busy = const {}, this.outcome});

  /// The member ids (`HouseholdMember.id`) with a request on its way.
  final Set<String> busy;

  /// What the last request answered, until dismissed or replaced.
  final HouseholdMemberOutcome? outcome;

  @override
  List<Object?> get props => [busy, outcome];
}
