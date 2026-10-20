import 'package:models/domain.dart';

import 'paginated_result.dart';

/// Who an invite is for: an existing user, or an email address.
sealed class HouseholdInvitee {
  const HouseholdInvitee();
}

/// An invite to a user picked from user search.
final class InviteeUser extends HouseholdInvitee {
  const InviteeUser(this.userId);

  final String userId;
}

/// An invite to an email address, which need not belong to a user yet.
final class InviteeEmail extends HouseholdInvitee {
  /// Trims [email]; an address typed with spaces around it is still that
  /// address.
  factory InviteeEmail(String email) => InviteeEmail._(email.trim());

  const InviteeEmail._(this.email);

  final String email;
}

/// What the send form submits (#455).
///
/// Normalises and validates in its constructor, so a draft that exists is
/// one the server's validation accepts in shape:
///
/// - [inviteeName] and [message] are trimmed, and stored as null when
///   nothing is left. The server omits an empty one the same way.
/// - [inviteeName] is at most [maxNameLength] characters and [message] at
///   most [maxMessageLength], counted after trimming.
/// - [role] is one an invite may offer: Admin, Member or Guest. Owner is
///   never offered.
///
/// Throws [ArgumentError] otherwise. Whether the sender may offer [role] is
/// the server's to decide, and its refusal is a
/// [HouseholdInviteRefusedException].
final class HouseholdInviteDraft {
  HouseholdInviteDraft({
    required this.invitee,
    String? inviteeName,
    this.role = HouseholdRole.householdMember,
    String? message,
  }) : inviteeName = _trimmed(inviteeName),
       message = _trimmed(message) {
    switch (invitee) {
      case InviteeUser(:final userId) when userId.isEmpty:
        throw ArgumentError.value(userId, 'invitee', 'empty user id');
      case InviteeEmail(:final email) when email.isEmpty:
        throw ArgumentError.value(email, 'invitee', 'empty email address');
      case InviteeUser() || InviteeEmail():
        break;
    }
    final name = this.inviteeName;
    if (name != null && name.length > maxNameLength) {
      throw ArgumentError.value(
        name.length,
        'inviteeName',
        'longer than $maxNameLength characters',
      );
    }
    final text = this.message;
    if (text != null && text.length > maxMessageLength) {
      throw ArgumentError.value(
        text.length,
        'message',
        'longer than $maxMessageLength characters',
      );
    }
    if (!offerableRoles.contains(role)) {
      throw ArgumentError.value(role, 'role', 'not a role an invite offers');
    }
  }

  /// The server's `@MaxLength` on `inviteeName`.
  static const int maxNameLength = 100;

  /// The server's `@MaxLength` on `message`.
  static const int maxMessageLength = 1000;

  /// The roles the server's `InviteRoleName` allows.
  static const Set<HouseholdRole> offerableRoles = {
    HouseholdRole.householdAdmin,
    HouseholdRole.householdMember,
    HouseholdRole.householdGuest,
  };

  final HouseholdInvitee invitee;
  final String? inviteeName;
  final HouseholdRole role;
  final String? message;

  static String? _trimmed(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

/// The answer to an accept: the invite, now accepted, and the household the
/// caller just joined.
///
/// The server's accept answer names the household only through the new
/// membership, so [householdId] is read from there.
typedef AcceptedHouseholdInvite = ({
  HouseholdInvite invite,
  String householdId,
});

/// Which limit a 402 hit, read from the refusal's own fields (#455).
///
/// The values are the server's: [resource] is `household_invite_daily_count`
/// or `household_member_count`, and [scope] is `Server`, `Household`,
/// `HouseholdMember` or `User`. They are kept as strings, because a limit
/// added server-side should still reach the screen as a 402 it can word
/// generally rather than fail to parse.
final class InviteQuota {
  const InviteQuota({required this.resource, required this.scope});

  /// The limited resource.
  final String resource;

  /// Whose limit it is.
  final String scope;
}

/// Remote data source for household invites (#455, #454, #489).
///
/// Online-only, like [DataGatewayRemoteDataSource]: nothing here is stored on
/// the device. Each invite screen reads the server when it opens, and every
/// action goes straight to it. Accepting an invite creates a membership,
/// which reaches the device through the household hydrate pass, not through
/// this interface.
///
/// It is a separate interface from [HouseholdRemoteDataSource] on purpose.
/// That one feeds the sync drain and classifies failures by whether a
/// queued operation should be retried; these calls are made by a person
/// waiting on a screen, and their refusals are answers to show them.
///
/// Implementations run over a **per-server** authenticated transport: the
/// injected client carries the base URL and the session.
///
/// ## Wire contract
///
/// Backend `libs/api/household` and `libs/api/user`, all under the `api`
/// global prefix:
///
/// | Method | Path | Answer |
/// |---|---|---|
/// | [send] | `POST /api/households/:hid/invites` | 201 `{ message, invite }` |
/// | [fetchHouseholdInvites] | `GET /api/households/:hid/invites` | `{ invites, pagination }` |
/// | [fetchInbox] | `GET /api/invites` | `{ invites, pagination }`; rows add `household` |
/// | [accept] | `POST /api/invites/:id/accept` | `{ message, invite, member }` |
/// | [decline] | `POST /api/invites/:id/decline` | `{ message, invite }` |
/// | [withdraw] | `POST /api/invites/:id/withdraw` | `{ message, invite }` |
/// | [revoke] | `POST /api/households/:hid/invites/:id/revoke` | `{ message, invite }` |
/// | [approve] | `POST /api/households/:hid/invites/:id/approve` | `{ message, invite }` |
/// | [searchUsers] | `GET /api/users/search` | `{ users, pagination }` |
///
/// The household list holds only open invites unless asked otherwise:
/// pending or awaiting approval, and not yet expired. It takes a `status`
/// to list one status instead, judged as it stands now, so an outstanding
/// invite past its expiry counts as expired. The inbox holds only pending,
/// unexpired invites into a live household the caller is not already in:
/// one awaiting approval is the household's to decide, and is not shown to
/// its invitee until it is approved.
///
/// ## Failure classification
///
/// Every transport failure is wrapped as a [HouseholdInviteRemoteException];
/// callers never see a raw transport error.
///
/// - [HouseholdInviteRefusedException]: the API answered and said no. A 400,
///   402, 403, 409 or 410 carrying the API's error envelope, or a 404
///   carrying it from a route naming one invite, or from [send]. A 404 on
///   [send] means the household is gone or the user picked has no account;
///   the server reads both before it answers, so it is a refusal there too,
///   though a server without the route would answer the same way. A 402
///   also carries the [InviteQuota] it hit.
/// - [HouseholdInviteTransientException]: no response at all, 401, 407, 408,
///   429, every 5xx, a 409 saying `retryable: true`, a 403 or 404 without the
///   envelope (a proxy answered, not the API), and a 404 with the envelope
///   from the inbox, the household list or user search. A list route is
///   never absent, and Nest's unmatched-route 404 carries the same envelope,
///   so there it may mean a server without the route. The household list
///   names a household, and a deleted one answers it with an enveloped 404
///   too; the two cannot be told apart, so it is read the cautious way.
/// - [HouseholdInvitePermanentException]: any other 4xx, and a 2xx whose body
///   cannot be read as the contract above.
///
/// The server's error bodies carry no stable code yet
/// (BoardGamesEmpire/board-games-empire-backend#822), so one status can mean
/// several things. A caller words a refusal from its status, and from a
/// 402's [InviteQuota]; it never shows the body's `message`, which the
/// server translates.
///
/// A call that cannot produce a valid request throws [ArgumentError]
/// unwrapped: a page below 1, a limit out of range, a status filter of
/// [HouseholdInviteStatus.unknown], or a search shorter than
/// [minSearchLength] after trimming.
abstract class HouseholdInviteRemoteDataSource {
  /// The page size the screens ask for.
  static const int defaultPageSize = 25;

  /// The backend's `limit` ceiling for invite lists. A larger limit is a 400,
  /// not clamped.
  static const int maxPageSize = 100;

  /// The backend's `limit` ceiling for user search. A larger limit is a 400,
  /// not clamped.
  static const int maxSearchPageSize = 20;

  /// The fewest characters user search accepts, after trimming.
  static const int minSearchLength = 2;

  /// Invites [draft]'s invitee to the household.
  ///
  /// The answer is the invite as created: [HouseholdInviteStatus.pending], or
  /// [HouseholdInviteStatus.awaitingApproval] when the household asks an
  /// owner or admin to approve invites from this sender.
  Future<HouseholdInvite> send(String householdId, HouseholdInviteDraft draft);

  /// One page of the household's invites, newest first, for its owners and
  /// admins: the open ones, or those with [status] when it is given.
  Future<PaginatedResult<HouseholdInvite>> fetchHouseholdInvites(
    String householdId, {
    HouseholdInviteStatus? status,
    int page = 1,
    int limit = defaultPageSize,
  });

  /// One page of the pending invites sent to the caller, by user or by a
  /// verified address, newest first. Each row names its household.
  Future<PaginatedResult<HouseholdInvite>> fetchInbox({
    int page = 1,
    int limit = defaultPageSize,
  });

  /// Accepts a pending invite sent to the caller, making them a member.
  Future<AcceptedHouseholdInvite> accept(String inviteId);

  /// Declines an invite sent to the caller.
  Future<HouseholdInvite> decline(String inviteId);

  /// Withdraws an invite the caller sent.
  Future<HouseholdInvite> withdraw(String inviteId);

  /// Revokes an outstanding invite to the household, as one of its owners or
  /// admins. On an invite awaiting approval this is turning it down. The
  /// invite's own inviter is refused, and withdraws it instead.
  Future<HouseholdInvite> revoke(String householdId, String inviteId);

  /// Approves an invite awaiting approval, making it pending. The server
  /// restarts its expiry from the approval. An owner or admin may approve
  /// one they sent themselves, as a member promoted since.
  Future<HouseholdInvite> approve(String householdId, String inviteId);

  /// Users whose username or name matches [query], to invite by account.
  ///
  /// [query] is trimmed, and must then be at least [minSearchLength]
  /// characters. [limit] is in `1..maxSearchPageSize`.
  Future<PaginatedResult<UserSummary>> searchUsers(
    String query, {
    int page = 1,
    int limit = maxSearchPageSize,
  });
}

/// Base class for every household invite remote failure.
sealed class HouseholdInviteRemoteException implements Exception {
  const HouseholdInviteRemoteException(
    this.message, {
    this.statusCode,
    this.cause,
  });

  /// A description for logs. Never shown to the user.
  final String message;

  /// The HTTP status, when the failure carried a response.
  final int? statusCode;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() =>
      '$runtimeType(message: $message, statusCode: $statusCode)';
}

/// The API refused the request: a 4xx carrying its error envelope.
/// [statusCode] is always set. [quota] is set on a 402.
final class HouseholdInviteRefusedException
    extends HouseholdInviteRemoteException {
  const HouseholdInviteRefusedException(
    super.message, {
    required int super.statusCode,
    this.quota,
    super.cause,
  });

  /// Which limit a 402 hit.
  final InviteQuota? quota;
}

/// The server refused the request in a way the API's contract does not
/// describe, and sending it again will not change that.
final class HouseholdInvitePermanentException
    extends HouseholdInviteRemoteException {
  const HouseholdInvitePermanentException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The request did not get an answer from the API that says anything about
/// it. Trying again later may work.
final class HouseholdInviteTransientException
    extends HouseholdInviteRemoteException {
  const HouseholdInviteTransientException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}
