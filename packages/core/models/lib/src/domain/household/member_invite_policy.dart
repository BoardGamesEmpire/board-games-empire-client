import 'package:freezed_annotation/freezed_annotation.dart';

/// Whether a household's members may invite, and how.
///
/// Mirrors the backend's `MemberInvitePolicy` enum, held on the household's
/// settings (board-games-empire-backend#166). Owners and admins always invite
/// directly and guests never do, whatever the policy. A change reaches a
/// member's invite still waiting too: the server asks again, when it is
/// approved or accepted, whether its sender could still send it, and an
/// invite an approver already approved is left alone
/// (board-games-empire-backend#747).
enum MemberInvitePolicy {
  /// A member's invite goes straight to the invitee.
  @JsonValue('Direct')
  direct,

  /// An owner or admin approves each member's invite first. The server's
  /// default.
  @JsonValue('NeedsApproval')
  needsApproval,

  /// Members cannot invite.
  @JsonValue('Off')
  off,

  /// A name this client does not know. Shown, never sent.
  unknown;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static MemberInvitePolicy fromWire(String name) => switch (name) {
    'Direct' => MemberInvitePolicy.direct,
    'NeedsApproval' => MemberInvitePolicy.needsApproval,
    'Off' => MemberInvitePolicy.off,
    _ => MemberInvitePolicy.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    MemberInvitePolicy.direct => 'Direct',
    MemberInvitePolicy.needsApproval => 'NeedsApproval',
    MemberInvitePolicy.off => 'Off',
    MemberInvitePolicy.unknown => throw StateError(
      'MemberInvitePolicy.unknown has no wire name',
    ),
  };
}
