import 'package:equatable/equatable.dart';

import '../invites/sent_invite_filter.dart';

/// Input to the list of invites the viewer sent (#487).
sealed class SentInvitesEvent extends Equatable {
  const SentInvitesEvent();

  @override
  List<Object?> get props => [];
}

/// Read the list again from the server. The rows on screen stay while it
/// runs.
final class SentInvitesLoadRequested extends SentInvitesEvent {
  const SentInvitesLoadRequested();
}

/// Show [filter]'s invites instead, read afresh.
final class SentInvitesFilterChanged extends SentInvitesEvent {
  const SentInvitesFilterChanged(this.filter);

  final SentInviteFilter filter;

  @override
  List<Object?> get props => [filter];
}

/// Read the next page and add it below the rows on screen.
final class SentInvitesMoreRequested extends SentInvitesEvent {
  const SentInvitesMoreRequested();
}

/// Take back the invite [inviteId].
final class SentInvitesWithdrawRequested extends SentInvitesEvent {
  const SentInvitesWithdrawRequested(this.inviteId);

  final String inviteId;

  @override
  List<Object?> get props => [inviteId];
}

/// The person closed the last withdraw's banner.
final class SentInvitesOutcomeDismissed extends SentInvitesEvent {
  const SentInvitesOutcomeDismissed();
}
