import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

import '../permissions/household_actions.dart';

/// Which of the household's invites the list shows.
enum HouseholdInviteFilter {
  /// Every open invite: pending or awaiting approval, not yet expired. What
  /// the server lists when asked for no status.
  open,

  /// Only the invites waiting on an owner or admin to approve them (#489).
  awaitingApproval,
}

/// What the household's invite list is showing (#455).
sealed class HouseholdInviteListState extends Equatable {
  const HouseholdInviteListState();

  @override
  List<Object?> get props => [];
}

/// The list is being read from the server, under [filter].
final class HouseholdInviteListLoading extends HouseholdInviteListState {
  const HouseholdInviteListLoading({this.filter = HouseholdInviteFilter.open});

  final HouseholdInviteFilter filter;

  @override
  List<Object?> get props => [filter];
}

/// The server refused the read: the viewer is not an owner or admin here.
final class HouseholdInviteListDenied extends HouseholdInviteListState {
  const HouseholdInviteListDenied();
}

/// The read failed for a reason that says nothing about access. Retryable.
final class HouseholdInviteListFailed extends HouseholdInviteListState {
  const HouseholdInviteListFailed();
}

/// The server's invites under [filter], newest first. May be empty.
final class HouseholdInviteListReady extends HouseholdInviteListState {
  const HouseholdInviteListReady({
    required this.invites,
    required this.filter,
    required this.hasMore,
    required this.loadingMore,
    required this.viewerUserId,
    required this.viewerRole,
    this.busy = const {},
    this.outcome,
  });

  final List<HouseholdInvite> invites;
  final HouseholdInviteFilter filter;

  /// Whether the server has more rows past the ones shown.
  final bool hasMore;

  /// Whether the next page is being read.
  final bool loadingMore;

  /// Who is looking, from the local cache. Null when it could not say, and
  /// then no row offers an action.
  final String? viewerUserId;
  final HouseholdRole? viewerRole;

  /// Ids of the rows with an action in flight.
  final Set<String> busy;

  /// What the last action answered, until dismissed or replaced.
  final HouseholdInviteListOutcome? outcome;

  /// The actions [invite]'s row offers the viewer.
  Set<HouseholdInviteRowAction> actionsFor(HouseholdInvite invite) {
    final viewer = viewerUserId;
    if (viewer == null) return const {};
    return householdInviteRowActions(
      viewerUserId: viewer,
      viewerRole: viewerRole,
      invite: invite,
    );
  }

  @override
  List<Object?> get props => [
    invites,
    filter,
    hasMore,
    loadingMore,
    viewerUserId,
    viewerRole,
    busy,
    outcome,
  ];
}

/// How an action on an invite ended.
enum HouseholdInviteActionResult {
  /// The server did it.
  done,

  /// The server said no. The outcome's error says why.
  refused,

  /// No answer that says anything about the invite.
  failed,
}

/// The last action's outcome, for the banner above the list.
final class HouseholdInviteListOutcome extends Equatable {
  const HouseholdInviteListOutcome({
    required this.action,
    required this.result,
    this.error,
  });

  final HouseholdInviteRowAction action;
  final HouseholdInviteActionResult result;

  /// What the action failed with, for `inviteRefusalMessage`. Null when it
  /// was done.
  final Object? error;

  @override
  List<Object?> get props => [action, result, error];
}
