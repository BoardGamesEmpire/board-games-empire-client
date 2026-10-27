import 'package:models/domain.dart';

/// Remote data source for acting on a household member: changing their role,
/// or removing them (#480, #483).
///
/// Online-only, like [HouseholdInviteRemoteDataSource]: each call is a person
/// waiting on a screen, so nothing is queued and nothing is stored on the
/// device (#122). A call that cannot reach the server fails, and the caller
/// says so. What an answer changes locally is the caller's to write, from
/// the member it returns.
///
/// It is a separate interface from [HouseholdRemoteDataSource] on purpose.
/// That one feeds the sync drain and classifies failures by whether a
/// queued operation should be retried; these calls are made by a person
/// waiting on a screen, and their refusals are answers to show them.
///
/// Leaving a household (#479) and transferring its ownership (#478) will add
/// `leave` and `transferOwnership` here.
///
/// Implementations run over a **per-server** authenticated transport: the
/// injected client carries the base URL and the session.
///
/// ## Wire contract
///
/// Backend `libs/api/household`, under the `api` global prefix. `:mid` is the
/// server's `HouseholdMember.id`, not the user's id.
///
/// | Method | Path | Answer |
/// |---|---|---|
/// | [changeRole] | `PATCH /api/households/:hid/members/:mid/role` | 200 `{ message, member }` |
/// | [remove] | `DELETE /api/households/:hid/members/:mid` | 200 `{ message, member }` |
///
/// [changeRole] sends `{ "role": "HouseholdAdmin" | "HouseholdMember" |
/// "HouseholdGuest" }`. `member` is in the shape the household list embeds
/// for each of its members.
///
/// ## Failure classification
///
/// Every transport failure is wrapped as a [HouseholdMemberRemoteException];
/// callers never see a raw transport error.
///
/// - [HouseholdMemberRefusedException]: the API answered and said no. A 400,
///   403, 404 or 409 carrying the API's error envelope. Both routes name a
///   member row, so an enveloped 404 is a refusal here. It most likely says
///   the member is gone, but Nest's unmatched-route 404 carries the same
///   envelope, so a server without the route answers it too. The two cannot
///   be told apart, so what a 404 means is the caller's to decide (#122).
/// - [HouseholdMemberTransientException]: no response at all, 401, 407, 408,
///   429, every 5xx, a 409 saying `retryable: true`, a 403 or 404 without the
///   envelope (a proxy answered, not the API), and a status that is no
///   verdict, a 1xx or 3xx.
/// - [HouseholdMemberPermanentException]: any other 4xx, a 400 or 409 without
///   the envelope included, and a 2xx whose body cannot be read as the
///   contract above, `member` included.
///
/// The server's error bodies carry no stable code yet
/// (BoardGamesEmpire/board-games-empire-backend#822), so one status can mean
/// several things. A caller words a refusal from its status; it never shows
/// the body's `message`, which the server translates.
///
/// A call that cannot produce a valid request throws [ArgumentError]
/// unwrapped: a [changeRole] to a role outside [assignableRoles].
abstract class HouseholdMemberRemoteDataSource {
  /// The roles a member can be given: the ones the server's role-change
  /// request accepts. Owner is not among them, because ownership moves only
  /// by transfer (#478).
  static const Set<HouseholdRole> assignableRoles = {
    HouseholdRole.householdAdmin,
    HouseholdRole.householdMember,
    HouseholdRole.householdGuest,
  };

  /// Gives the member [memberId] of the household the role [role].
  ///
  /// [memberId] is the membership's own id. The answer is the member as it
  /// now stands.
  ///
  /// Throws [ArgumentError], before any request, when [role] is not in
  /// [assignableRoles]. Whether the caller may give it, to this member, is
  /// the server's to decide, and its refusal is a
  /// [HouseholdMemberRefusedException].
  Future<HouseholdMember> changeRole(
    String householdId,
    String memberId,
    HouseholdRole role,
  );

  /// Removes the member [memberId] from the household.
  ///
  /// [memberId] is the membership's own id. The answer is the member that
  /// was removed.
  Future<HouseholdMember> remove(String householdId, String memberId);
}

/// Base class for every household member remote failure.
sealed class HouseholdMemberRemoteException implements Exception {
  const HouseholdMemberRemoteException(
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
/// [statusCode] is always set.
final class HouseholdMemberRefusedException
    extends HouseholdMemberRemoteException {
  const HouseholdMemberRefusedException(
    super.message, {
    required int super.statusCode,
    super.cause,
  });
}

/// The server refused the request in a way the API's contract does not
/// describe, and sending it again will not change that.
final class HouseholdMemberPermanentException
    extends HouseholdMemberRemoteException {
  const HouseholdMemberPermanentException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The request did not get an answer from the API that says anything about
/// it. Trying again later may work.
final class HouseholdMemberTransientException
    extends HouseholdMemberRemoteException {
  const HouseholdMemberTransientException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}
