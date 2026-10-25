import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

import '../invites/sent_invite_filter.dart';
import 'household_invite_list_state.dart';

/// What the list of invites the viewer sent is showing (#487).
sealed class SentInvitesState extends Equatable {
  const SentInvitesState();

  @override
  List<Object?> get props => [];
}

/// The list is being read from the server, under [filter].
final class SentInvitesLoading extends SentInvitesState {
  const SentInvitesLoading({this.filter = SentInviteFilter.openAndExpired});

  final SentInviteFilter filter;

  @override
  List<Object?> get props => [filter];
}

/// The read failed. Retryable. The server refuses this read only to an API
/// key, so a refusal is no different from any other failure here.
final class SentInvitesFailed extends SentInvitesState {
  const SentInvitesFailed();
}

/// The server's invites under [filter], newest first. May be empty.
final class SentInvitesReady extends SentInvitesState {
  const SentInvitesReady({
    required this.invites,
    required this.filter,
    required this.hasMore,
    required this.loadingMore,
    this.busy = const {},
    this.outcome,
  });

  final List<HouseholdInvite> invites;
  final SentInviteFilter filter;

  /// Whether the server has more rows past the ones shown.
  final bool hasMore;

  /// Whether the next page is being read.
  final bool loadingMore;

  /// Ids of the rows with a withdraw in flight.
  final Set<String> busy;

  /// What the last withdraw answered, until dismissed or replaced. Its
  /// action is always withdraw.
  final HouseholdInviteListOutcome? outcome;

  @override
  List<Object?> get props => [
    invites,
    filter,
    hasMore,
    loadingMore,
    busy,
    outcome,
  ];
}
