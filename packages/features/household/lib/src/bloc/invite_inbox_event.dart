import 'package:equatable/equatable.dart';

import '../invites/invite_refusal_message.dart';

/// Input to the invite inbox (#455).
sealed class InviteInboxEvent extends Equatable {
  const InviteInboxEvent();

  @override
  List<Object?> get props => [];
}

/// Read the inbox again. The rows on screen stay while it runs.
final class InviteInboxLoadRequested extends InviteInboxEvent {
  const InviteInboxLoadRequested();
}

/// Read the next page and add it below the rows on screen.
final class InviteInboxMoreRequested extends InviteInboxEvent {
  const InviteInboxMoreRequested();
}

/// Answer the invite [inviteId]: [HouseholdInviteAction.accept] or
/// [HouseholdInviteAction.decline]. Any other action is ignored.
final class InviteInboxAnswerRequested extends InviteInboxEvent {
  const InviteInboxAnswerRequested(this.action, this.inviteId);

  final HouseholdInviteAction action;
  final String inviteId;

  @override
  List<Object?> get props => [action, inviteId];
}

/// The person closed the last answer's banner.
final class InviteInboxOutcomeDismissed extends InviteInboxEvent {
  const InviteInboxOutcomeDismissed();
}
