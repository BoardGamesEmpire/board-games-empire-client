import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What the Add people page needs from the event detail beneath it (#510).
///
/// The detail works both out from what it shows as Add people is pressed,
/// and only an open detail has them: the page reads no event of its own.
final class AddAttendeeArgs extends Equatable {
  const AddAttendeeArgs({required this.roles, this.rosterUserIds = const {}});

  /// The roles the viewer may give, from `assignableEventRoles`, in its
  /// order. Never empty.
  final List<EventRole> roles;

  /// The user ids the cached roster holds. The page picks none of them.
  final Set<String> rosterUserIds;

  @override
  List<Object?> get props => [roles, rosterUserIds];
}

/// Who to add, and with which role, as the Add people page answers it
/// (#510). The detail sends it.
final class EventAttendeeAddition extends Equatable {
  const EventAttendeeAddition({required this.user, required this.role});

  /// The person picked from the search.
  final UserSummary user;

  /// One of [AddAttendeeArgs.roles].
  final EventRole role;

  @override
  List<Object?> get props => [user, role];
}
