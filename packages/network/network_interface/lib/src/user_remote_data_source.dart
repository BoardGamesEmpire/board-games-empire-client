import 'package:models/domain.dart';

import 'paginated_result.dart';

/// Remote data source for finding other users by name (#455, #499).
///
/// Online-only, like [HouseholdInviteRemoteDataSource]: nothing here is stored
/// on the device, and every search goes straight to the server.
///
/// It is a separate interface from [HouseholdInviteRemoteDataSource] on
/// purpose. More than one feature picks people by searching: the household
/// invite form (#455) and the event create form's invitees (#499). Neither
/// owns the search.
///
/// Implementations run over a **per-server** authenticated transport: the
/// injected client carries the base URL and the session.
///
/// ## Wire contract
///
/// Backend `libs/api/user`, under the `api` global prefix:
///
/// | Method | Path | Answer |
/// |---|---|---|
/// | [searchUsers] | `GET /api/users/search` | `{ users, pagination }` |
///
/// ## Failure classification
///
/// Every transport failure is wrapped as a [UserRemoteException]; callers
/// never see a raw transport error.
///
/// - [UserRemoteTransientException]: no response at all, 401, 407, 408, 429,
///   every 5xx, a 409 saying `retryable: true`, a 403 or 404 without the API's
///   error envelope (a proxy answered, not the API), a 404 even with it, and a
///   2xx body this device could not decode at all. A list route is never
///   absent, and Nest's unmatched-route 404 carries the same envelope, so an
///   enveloped 404 here may mean a server without the route.
/// - [UserRemotePermanentException]: any other 4xx (a 400 for a value the
///   server rejects, and a 403 carrying the envelope), and a 2xx whose body
///   cannot be read as the contract above.
///
/// Unlike the household invite remote, search has no refusal type of its own:
/// the API saying no is a [UserRemotePermanentException].
///
/// A call that cannot produce a valid request throws [ArgumentError]
/// unwrapped: a search shorter than [minSearchLength] after trimming, a page
/// below 1, or a limit out of range.
abstract class UserRemoteDataSource {
  /// The backend's `limit` ceiling for user search. A larger limit is a 400,
  /// not clamped.
  static const int maxSearchPageSize = 20;

  /// The fewest characters user search accepts, after trimming.
  static const int minSearchLength = 2;

  /// Users whose username or name matches [query].
  ///
  /// [query] is trimmed, and must then be at least [minSearchLength]
  /// characters. [page] is 1-based and [limit] is in `1..maxSearchPageSize`.
  Future<PaginatedResult<UserSummary>> searchUsers(
    String query, {
    int page = 1,
    int limit = maxSearchPageSize,
  });
}

/// Base class for every user remote failure.
sealed class UserRemoteException implements Exception {
  const UserRemoteException(this.message, {this.statusCode, this.cause});

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

/// The server refused the request, and sending it again will not change that.
final class UserRemotePermanentException extends UserRemoteException {
  const UserRemotePermanentException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The request did not get an answer from the API that says anything about
/// it. Trying again later may work.
final class UserRemoteTransientException extends UserRemoteException {
  const UserRemoteTransientException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}
