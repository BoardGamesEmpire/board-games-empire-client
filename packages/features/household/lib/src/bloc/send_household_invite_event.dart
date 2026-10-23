import 'package:equatable/equatable.dart';
import 'package:network_interface/network_interface.dart';

/// Input to the send form (#455).
sealed class SendHouseholdInviteEvent extends Equatable {
  const SendHouseholdInviteEvent();

  @override
  List<Object?> get props => [];
}

/// Send [draft].
final class SendHouseholdInviteSubmitted extends SendHouseholdInviteEvent {
  const SendHouseholdInviteSubmitted(this.draft);

  final HouseholdInviteDraft draft;

  @override
  List<Object?> get props => [draft];
}

/// The person changed the form. A failure on show describes the value being
/// replaced, so it goes.
final class SendHouseholdInviteEdited extends SendHouseholdInviteEvent {
  const SendHouseholdInviteEdited();
}
