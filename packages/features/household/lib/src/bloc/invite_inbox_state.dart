import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

import '../invites/invite_refusal_message.dart';
import 'household_invite_list_state.dart';

/// What the invite inbox is showing (#455).
sealed class InviteInboxState extends Equatable {
  const InviteInboxState();

  @override
  List<Object?> get props => [];
}

/// The inbox is being read from the server.
final class InviteInboxLoading extends InviteInboxState {
  const InviteInboxLoading();
}

/// The read failed. Retryable.
final class InviteInboxFailed extends InviteInboxState {
  const InviteInboxFailed();
}

/// The open invites sent to the user, newest first. May be empty.
final class InviteInboxReady extends InviteInboxState {
  const InviteInboxReady({
    required this.invites,
    required this.hasMore,
    required this.loadingMore,
    this.busy = const {},
    this.outcome,
  });

  final List<HouseholdInvite> invites;
  final bool hasMore;
  final bool loadingMore;

  /// Ids of the invites with an answer in flight.
  final Set<String> busy;

  /// How the last answer went, until dismissed or replaced.
  final InviteInboxOutcome? outcome;

  @override
  List<Object?> get props => [invites, hasMore, loadingMore, busy, outcome];
}

/// How an answer to an invite went, for the banner above the inbox.
final class InviteInboxOutcome extends Equatable {
  const InviteInboxOutcome({
    required this.action,
    required this.result,
    required this.householdName,
    this.householdId,
    this.error,
  });

  /// [HouseholdInviteAction.accept] or [HouseholdInviteAction.decline].
  final HouseholdInviteAction action;
  final HouseholdInviteActionResult result;

  /// The household the invite was to, as its row named it.
  final String householdName;

  /// The household joined. Set only after an accept that was done.
  final String? householdId;

  /// What the answer failed with, for `inviteRefusalMessage`.
  final Object? error;

  @override
  List<Object?> get props => [
    action,
    result,
    householdName,
    householdId,
    error,
  ];
}
