import 'package:equatable/equatable.dart';

/// What a notification opens when the user taps it (#475).
///
/// The feature says where in the app's own terms; app_shell turns a target
/// into a location, so this package names no route. Switch over it
/// exhaustively: more kinds of notification bring more targets.
sealed class NotificationTarget extends Equatable {
  const NotificationTarget();

  @override
  List<Object?> get props => const [];
}

/// The invites sent to the user, where they accept or decline them.
final class InviteInboxTarget extends NotificationTarget {
  const InviteInboxTarget();
}

/// A household's own page.
final class HouseholdTarget extends NotificationTarget {
  const HouseholdTarget(this.householdId);

  final String householdId;

  @override
  List<Object?> get props => [householdId];
}

/// A household's invites, on the invites awaiting approval when
/// [awaitingApproval] is true.
final class HouseholdInvitesTarget extends NotificationTarget {
  const HouseholdInvitesTarget(
    this.householdId, {
    required this.awaitingApproval,
  });

  final String householdId;
  final bool awaitingApproval;

  @override
  List<Object?> get props => [householdId, awaitingApproval];
}

/// Where a declined household invite is listed, which depends on the
/// user's role there: the household's invites for its owners and admins,
/// and the invites the user sent for anyone else. The notification doesn't
/// say who sent the invite, so app_shell decides.
final class DeclinedInviteTarget extends NotificationTarget {
  const DeclinedInviteTarget(this.householdId);

  final String householdId;

  @override
  List<Object?> get props => [householdId];
}
