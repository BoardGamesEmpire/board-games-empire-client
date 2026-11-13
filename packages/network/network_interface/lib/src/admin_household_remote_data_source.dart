import 'package:models/domain.dart';

import 'package:network_interface/src/paginated_result.dart';
import 'package:network_interface/src/server_string_length.dart';

/// Remote data source for the staff households section (#685).
///
/// Server staff read every household on the server, and restore a deleted one.
/// There is no local copy: the screen reads through this each time it opens.
///
/// Implementations run over a **per-server** authenticated transport, like
/// [DataGatewayRemoteDataSource]: the injected client carries the base URL and
/// the session, and this interface adds no auth handling of its own.
///
/// ## Wire contract
///
/// Backend `libs/api/household`, all under the `api` global prefix:
///
/// | Method | Path | Body |
/// |---|---|---|
/// | [fetchPage] | `GET /api/admin/households?status&sort&page&limit[&q]` | `{ households: [...], pagination }` |
/// | [fetchDetail] | `GET /api/households/:id` | `{ household: { ..., languageTag: { name } \| null, members: [...] } }` |
/// | [restore] | `POST /api/households/:id/restore` | 2xx. The body isn't read |
///
/// ## Failures
///
/// - [AdminHouseholdForbiddenException]: an enveloped 403 on any route.
/// - [AdminHouseholdNotFoundException]: an enveloped 404 from [fetchDetail] or
///   [restore]. From [restore] it means "nothing this caller may restore",
///   which is how a Moderator's restore is answered.
/// - [AdminHouseholdNotDeletedException]: an enveloped 409 from [restore]. The
///   household is already live, which the caller treats as done.
/// - [AdminHouseholdTransientException] and
///   [AdminHouseholdPermanentException]: the shared rules, including a 404 on
///   the list route (not deployed) and a retryable 409.
/// - [ArgumentError], unwrapped: `page < 1`, `limit` outside `1..maxPageSize`,
///   a `sort` that is not [AdminHouseholdSort.allowedWith] the `status`, or a
///   non-null `query` whose trimmed [queryLength] is outside
///   `minQueryLength..maxQueryLength`.
abstract class AdminHouseholdRemoteDataSource {
  /// The most rows the server returns in one page.
  static const int maxPageSize = 100;

  /// The page size the list asks for.
  static const int pageSize = 25;

  /// The shortest search term the server takes, once trimmed.
  static const int minQueryLength = 2;

  /// The longest search term the server takes, once trimmed.
  static const int maxQueryLength = 100;

  /// How long the server counts [text] to be.
  ///
  /// See [serverStringLength], which holds the rule. Check a term with this,
  /// so one the client sends is never refused for its length.
  static int queryLength(String text) => serverStringLength(text);

  /// One page of the server's households.
  ///
  /// [query] matches part of a household's name, or of a member's username or
  /// display name, ignoring case. It is trimmed before it is sent.
  Future<PaginatedResult<AdminHouseholdRow>> fetchPage({
    AdminHouseholdStatus status = AdminHouseholdStatus.live,
    String? query,
    AdminHouseholdSort sort = AdminHouseholdSort.name,
    int page = 1,
    int limit = pageSize,
  });

  /// The household [id] with its members.
  ///
  /// Throws [AdminHouseholdNotFoundException] when it is gone or deleted.
  Future<AdminHouseholdDetail> fetchDetail(String id);

  /// Restores the deleted household [id].
  ///
  /// Throws [AdminHouseholdNotFoundException] when there is nothing this
  /// caller may restore, and [AdminHouseholdNotDeletedException] when the
  /// household is already live.
  Future<void> restore(String id);
}

/// Base class for every staff households remote failure.
sealed class AdminHouseholdRemoteException implements Exception {
  const AdminHouseholdRemoteException(
    this.message, {
    this.statusCode,
    this.cause,
  });

  final String message;

  /// The HTTP status, when the failure carried a response.
  final int? statusCode;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() =>
      // toString names the concrete subclass, so it needs the runtime type.
      // ignore: no_runtimetype_tostring
      '$runtimeType(message: $message, statusCode: $statusCode)';
}

/// The caller's role may not do this: a 403 from the API itself.
final class AdminHouseholdForbiddenException
    extends AdminHouseholdRemoteException {
  const AdminHouseholdForbiddenException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The household does not exist, was deleted, or there is nothing this caller
/// may restore.
final class AdminHouseholdNotFoundException
    extends AdminHouseholdRemoteException {
  const AdminHouseholdNotFoundException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// A restore of a household that is not deleted: it is live already.
final class AdminHouseholdNotDeletedException
    extends AdminHouseholdRemoteException {
  const AdminHouseholdNotDeletedException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The server refused the request, and sending it again will not change that.
final class AdminHouseholdPermanentException
    extends AdminHouseholdRemoteException {
  const AdminHouseholdPermanentException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The request did not get an answer from the API that says anything about
/// it. Trying again later may work.
final class AdminHouseholdTransientException
    extends AdminHouseholdRemoteException {
  const AdminHouseholdTransientException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}
