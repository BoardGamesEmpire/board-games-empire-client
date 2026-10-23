import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Where the send form stands (#455).
sealed class SendHouseholdInviteState extends Equatable {
  const SendHouseholdInviteState();

  @override
  List<Object?> get props => [];
}

/// Nothing sent yet.
final class SendHouseholdInviteEditing extends SendHouseholdInviteState {
  const SendHouseholdInviteEditing();
}

/// The invite is on its way.
final class SendHouseholdInviteSending extends SendHouseholdInviteState {
  const SendHouseholdInviteSending();
}

/// The server created [invite].
final class SendHouseholdInviteSent extends SendHouseholdInviteState {
  const SendHouseholdInviteSent(this.invite);

  final HouseholdInvite invite;

  @override
  List<Object?> get props => [invite];
}

/// The send failed with [error], for `inviteRefusalMessage`. The form stays
/// filled in, to fix and send again.
final class SendHouseholdInviteFailed extends SendHouseholdInviteState {
  const SendHouseholdInviteFailed(this.error);

  final Object error;

  @override
  List<Object?> get props => [error];
}
