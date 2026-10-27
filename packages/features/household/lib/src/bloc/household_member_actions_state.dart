import 'package:equatable/equatable.dart';

import '../permissions/household_actions.dart';

/// How a role change or removal ended (#480).
enum HouseholdMemberActionResult {
  /// The server did it, and its answer is cached.
  done,

  /// The server says the member is not in the household, or that the
  /// household is gone: its 404 does not say which (#122). On a removal
  /// either way they are out of it; on a role change there is no one to
  /// change.
  gone,

  /// The server said no, with a 400, 403 or 409. The outcome's error says
  /// which.
  refused,

  /// No answer that says what happened. The outcome's error says why.
  failed,
}

/// The last member action's outcome, for the banner on the household screen
/// (#480).
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

/// The role changes and removals on one household screen (#480).
final class HouseholdMemberActionsState extends Equatable {
  const HouseholdMemberActionsState({this.busy = const {}, this.outcome});

  /// The member ids (`HouseholdMember.id`) with a request on its way.
  final Set<String> busy;

  /// What the last request answered, until dismissed or replaced.
  final HouseholdMemberOutcome? outcome;

  @override
  List<Object?> get props => [busy, outcome];
}
