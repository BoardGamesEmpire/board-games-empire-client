import 'package:freezed_annotation/freezed_annotation.dart';

import '../user/user_summary.dart';
import 'household_invite_status.dart';
import 'household_role.dart';

part 'household_invite.freezed.dart';

/// An invitation to join a household (#455).
///
/// Online-only: read from the server whenever an invite screen opens and
/// never stored on the device. Accepting one creates a membership, and the
/// household then arrives through the ordinary hydrate pass.
///
/// The same type serves all three lists. A household's own list leaves
/// [householdId] and [householdName] null, since the screen already knows
/// them; the invitee's inbox and the sender's sent list set both, since
/// their rows come from many households.
@freezed
abstract class HouseholdInvite with _$HouseholdInvite {
  const HouseholdInvite._();

  const factory HouseholdInvite({
    required String id,
    required HouseholdInviteStatus status,
    required UserSummary inviter,

    /// The role accepting would grant. Null when the server sends none.
    HouseholdRole? role,

    /// What the inviter called the invitee. Optional on send.
    String? inviteeName,

    /// The address an email invite went to. The server shows it to the
    /// household's owners and admins, to the invitee, and to the sender on the
    /// sent list.
    String? inviteeEmail,
    String? message,

    /// Set only on inbox and sent rows.
    String? householdId,

    /// Set only on inbox and sent rows.
    String? householdName,
    required DateTime expiresAt,
    required DateTime createdAt,
  }) = _HouseholdInvite;

  /// Who the invite is for, as far as the row says. Null for an invite by
  /// user id that the inviter gave no name.
  String? get inviteeLabel => inviteeName ?? inviteeEmail;
}
