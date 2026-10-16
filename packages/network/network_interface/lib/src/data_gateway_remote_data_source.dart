import 'package:models/domain.dart';

import 'paginated_result.dart';

/// Remote data source for the server's DataGateways (#41).
///
/// Admin configuration with no local copy: the admin screen reads through this
/// every time it opens, and every change goes straight to the server (#41).
///
/// Implementations run over a **per-server** authenticated transport, like
/// [HouseholdRemoteDataSource]: the injected client carries the base URL and
/// the session, and this interface adds no auth handling of its own.
///
/// ## Wire contract
///
/// Backend `libs/api/data-gateway`, all under the `api` global prefix:
///
/// | Method | Path | Body |
/// |---|---|---|
/// | [fetchPage] | `GET /api/data-gateways` | `{ dataGateways: [...], pagination }` |
/// | [fetchOne] | `GET /api/data-gateways/:id` | `{ dataGateway }` |
/// | [create] | `POST /api/data-gateways` | `{ dataGateway, connection_response, connection_attempt }` |
/// | [update] | `PATCH /api/data-gateways/:id` | `{ dataGateway, connection_response, connection_attempt }` |
/// | [delete] | `DELETE /api/data-gateways/:id` | `{ dataGateway, disconnection_response, disconnection_attempt }` |
/// | [connect] | `POST /api/data-gateways/:id/connect` | `{ dataGateway, connection_response, connection_attempt }` |
/// | [disconnect] | `POST /api/data-gateways/:id/disconnect` | `{ dataGateway, disconnection_response, disconnection_attempt }` |
///
/// A connect or disconnect the server could not complete still answers 2xx,
/// with `success: false` in its response. That is a
/// [DataGatewayConnectionAttempt] that did not succeed, not an exception.
///
/// Every response row carries `authParameters`, the stored credentials, until
/// backend#753. Implementations must not read it; [DataGateway] has nowhere to
/// put it (#41).
///
/// ## Who may call what
///
/// Owner and Admin may read and change DataGateways. Moderator may read them
/// and not change them. Any other role may do neither. Each refusal is a 403
/// carrying the API's error envelope, which surfaces as
/// [DataGatewayForbiddenException]. No route says in advance which of these
/// the caller is (#41).
///
/// ## Failure classification
///
/// Every transport failure is wrapped as a [DataGatewayRemoteException];
/// callers never see a raw transport error.
///
/// - [DataGatewayForbiddenException]: a 403 carrying the API's error envelope.
/// - [DataGatewayNotFoundException]: a 404 carrying the envelope, from a route
///   naming one DataGateway. It does not exist, or was deleted.
/// - [DataGatewayNameInUseException]: a 409 carrying the envelope. Another live
///   DataGateway has the name. The backend answers a duplicate name with a 500
///   until backend#754 lands, which is a [DataGatewayTransientException].
/// - [DataGatewayPermanentException]: any other 4xx the transient rule below
///   leaves out (a 400 for a value the server rejects, mostly), and a 2xx
///   whose body cannot be read as the contract above.
/// - [DataGatewayTransientException]: no response at all, 401, 407, 408, 429,
///   every 5xx, a 403 or 404 without the envelope (a proxy answered, not the
///   API), a 404 from [fetchPage] even with it (a list route is never absent,
///   so the route is not deployed), and a 2xx body this device could not
///   decode at all.
///
/// The envelope requirement is the household and collection rule (#350, #365,
/// #253): only the application's own answer licenses a conclusion about the
/// caller's role or about a row.
///
/// A call that cannot produce a valid request throws [ArgumentError]
/// unwrapped: an out-of-range page, a port outside 1–65535, or an empty
/// [DataGatewayChanges].
abstract class DataGatewayRemoteDataSource {
  /// The backend's `limit` ceiling (`DEFAULT_MAX_PAGE_SIZE`). A larger limit is
  /// a 400, not clamped.
  static const int maxPageSize = 100;

  /// One page of live DataGateways, alphabetical by name.
  ///
  /// Follow [PaginationMeta.hasMore] to the end of the list. [page] is 1-based
  /// and [limit] is in `1..maxPageSize`.
  Future<PaginatedResult<DataGateway>> fetchPage({
    int page = 1,
    int limit = maxPageSize,
  });

  /// One live DataGateway.
  ///
  /// Throws [DataGatewayNotFoundException] when there is none with [id].
  Future<DataGateway> fetchOne(String id);

  /// Creates a DataGateway with the "None" auth type and no credentials (#41).
  ///
  /// It is created enabled, the server's default, so the server tries to
  /// connect to it before answering; the result carries that attempt.
  Future<DataGatewayChangeResult> create(DataGatewayInput input);

  /// Sends [changes] alone. Throws [ArgumentError] when it is empty, because
  /// the server refuses an empty update with a 400.
  ///
  /// The server reconnects the DataGateway with its new settings on its own,
  /// so the result carries no connection attempt.
  Future<DataGatewayChangeResult> update(String id, DataGatewayChanges changes);

  /// Deletes the DataGateway, disconnecting it first when it was enabled.
  Future<DataGatewayChangeResult> delete(String id);

  /// Enables the DataGateway and tries to connect to it.
  Future<DataGatewayChangeResult> connect(String id);

  /// Disables the DataGateway and tries to disconnect from it.
  Future<DataGatewayChangeResult> disconnect(String id);
}

/// Base class for every DataGateway remote failure.
sealed class DataGatewayRemoteException implements Exception {
  const DataGatewayRemoteException(this.message, {this.statusCode, this.cause});

  final String message;

  /// The HTTP status, when the failure carried a response.
  final int? statusCode;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() =>
      '$runtimeType(message: $message, statusCode: $statusCode)';
}

/// The caller's role may not do this: a 403 from the API itself.
final class DataGatewayForbiddenException extends DataGatewayRemoteException {
  const DataGatewayForbiddenException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The named DataGateway does not exist, or was deleted.
final class DataGatewayNotFoundException extends DataGatewayRemoteException {
  const DataGatewayNotFoundException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// Another live DataGateway already has this name.
final class DataGatewayNameInUseException extends DataGatewayRemoteException {
  const DataGatewayNameInUseException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The server refused the request, and sending it again will not change that.
final class DataGatewayPermanentException extends DataGatewayRemoteException {
  const DataGatewayPermanentException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The request did not get an answer from the API that says anything about
/// it. Trying again later may work.
final class DataGatewayTransientException extends DataGatewayRemoteException {
  const DataGatewayTransientException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}
