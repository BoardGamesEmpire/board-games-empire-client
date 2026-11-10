import 'package:models/domain.dart';

import 'package:network_interface/src/paginated_result.dart';

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
/// | [setDisabledCapabilities] | `PATCH /api/data-gateways/:id` | `{ dataGateway, connection_response, connection_attempt }` |
/// | [delete] | `DELETE /api/data-gateways/:id` | `{ dataGateway, disconnection_response, disconnection_attempt }` |
/// | [connect] | `POST /api/data-gateways/:id/connect` | `{ dataGateway, connection_response, connection_attempt }` |
/// | [disconnect] | `POST /api/data-gateways/:id/disconnect` | `{ dataGateway, disconnection_response, disconnection_attempt }` |
/// | [interview] | `POST /api/data-gateways/:id/interview` | `{ dataGateway, interview_attempt, interview_response }` |
/// | [fetchLanguageLinks] | `GET /api/data-gateways/:id/language-links` | `{ languageLinks: [...], pagination }` |
/// | [linkLanguageLink] | `POST /api/data-gateways/:id/language-links/:linkId/link` | `{ languageLink }` |
/// | [ignoreLanguageLink] | `POST /api/data-gateways/:id/language-links/:linkId/ignore` | `{ languageLink }` |
/// | [acceptLanguageLink] | `POST /api/data-gateways/:id/language-links/:linkId/accept` | `{ languageLink }` |
/// | [fetchLanguageTags] | `GET /api/languages` | `{ languages: [{ ..., tags: [...] }], pagination }` |
///
/// A connect or disconnect the server could not complete still answers 2xx,
/// with `success: false` in its response. That is a
/// [DataGatewayConnectionAttempt] that did not succeed, not an exception. An
/// [interview] it could not complete answers the same way, as a
/// [DataGatewayInterviewResult] that did not succeed.
///
/// A response row carries no stored credentials since backend#753, only
/// `hasAuthParameters`. Implementations must not read even that;
/// [DataGateway] has nowhere to put it (#41).
///
/// ## Who may call what
///
/// Owner and Admin may read and change DataGateways. Moderator may read them
/// and not change them. Any other role may do neither. Each refusal is a 403
/// carrying the API's error envelope, which surfaces as
/// [DataGatewayForbiddenException]. No route says in advance which of these
/// the caller is (#41).
///
/// The language link routes are gated the same way: the worklist is a read,
/// and linking, ignoring and accepting a link are changes. The tag catalogue is
/// not gated by role, so [fetchLanguageTags] has no refusal of its own.
///
/// ## Failure classification
///
/// Every transport failure is wrapped as a [DataGatewayRemoteException];
/// callers never see a raw transport error.
///
/// - [DataGatewayForbiddenException]: a 403 carrying the API's error envelope.
/// - [DataGatewayNotFoundException]: a 404 carrying the envelope, from a route
///   naming one DataGateway. It does not exist, or was deleted. On a language
///   link action it also says the link is not one of that DataGateway's.
/// - [DataGatewayNameInUseException]: a 409 carrying the envelope and not
///   `retryable: true`, from [create] or [update]. Another live DataGateway
///   has the name. The backend answers a duplicate name with a 500 until
///   backend#754 lands, which is a [DataGatewayTransientException].
/// - [DataGatewayConflictException]: the same 409 from any other route, where
///   it cannot be a name clash: [interview], which answers it for a DataGateway
///   that is disabled, and [acceptLanguageLink], which answers it for a link
///   that cannot be accepted, are the ones known to.
/// - [DataGatewayPermanentException]: any other 4xx the transient rule below
///   leaves out (a 400 carrying the envelope for a value the server rejects,
///   mostly, such as the tag [linkLanguageLink] names not existing), and a 2xx
///   whose body cannot be read as the contract above.
/// - [DataGatewayTimedOutException]: no answer to an [interview] in time. The
///   server may keep interviewing after the caller gives up, so this says
///   nothing about the outcome. Outside a browser, an [interview] that could
///   not even connect is not this: it is transient, since it never left.
/// - [DataGatewayTransientException]: no response at all (bar the timeout
///   above), 401, 407, 408, 429, every 5xx, a 400, 403 or 404 without the
///   envelope (a proxy answered, not the API), a 404 from [fetchPage] even with
///   it (a list route is never absent, so the route is not deployed), a 409
///   saying `retryable: true` (a deadlock the server asks the caller to retry),
///   and a 2xx body this device could not decode at all.
///
/// The envelope requirement is the household and collection rule (#350, #365,
/// #253): only the application's own answer licenses a conclusion about the
/// caller's role or about a row.
///
/// A call that cannot produce a valid request throws [ArgumentError]
/// unwrapped: an out-of-range page or limit, a port outside 1–65535, an empty
/// [DataGatewayChanges], or an empty set of link statuses.
abstract class DataGatewayRemoteDataSource {
  /// The backend's `limit` ceiling (`DEFAULT_MAX_PAGE_SIZE`). A larger limit is
  /// a 400, not clamped. It is the ceiling of [fetchPage] and
  /// [fetchLanguageLinks].
  static const int maxPageSize = 100;

  /// The page size [fetchLanguageLinks] asks for when it is given none.
  static const int languageLinkPageSize = 50;

  /// The language catalogue's `limit` ceiling, and the page size
  /// [fetchLanguageTags] asks for when it is given none. A larger limit is a
  /// 400, not clamped.
  static const int languageTagPageSize = 50;

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

  /// Sets the capabilities the server does not route to [disabled], as the
  /// whole list: an empty one switches every capability back on.
  ///
  /// Names are the server's own spellings ([DataGatewayCapabilities]) and go
  /// out in the order given. [disabled] may name one the DataGateway does not
  /// declare yet, which stays off once it does. The server stores the list in
  /// its own order with no repeats, so read the list back from the result.
  ///
  /// A list switched back on is queued to load again straight away, so the
  /// row in the result does not show that load yet. As with [update], the
  /// result carries no connection attempt.
  Future<DataGatewayChangeResult> setDisabledCapabilities(
    String id,
    List<String> disabled,
  );

  /// Deletes the DataGateway, disconnecting it first when it was enabled.
  Future<DataGatewayChangeResult> delete(String id);

  /// Enables the DataGateway and tries to connect to it.
  Future<DataGatewayChangeResult> connect(String id);

  /// Disables the DataGateway and tries to disconnect from it.
  Future<DataGatewayChangeResult> disconnect(String id);

  /// Interviews the DataGateway now, however recent its last interview.
  ///
  /// The server waits for the interview before it answers, and sets no
  /// deadline of its own, so this waits longer than the other calls do. The
  /// result carries the row read again, whose `interview` shows how it went.
  /// An interview the server could not complete is a result with `succeeded`
  /// false, not an exception.
  ///
  /// Throws [DataGatewayConflictException] when the DataGateway is disabled,
  /// and [DataGatewayTimedOutException] when no answer comes in time: the
  /// server may still be interviewing, so read the row again before sending
  /// this twice.
  Future<DataGatewayInterviewResult> interview(String id);

  /// One page of the DataGateway's language links, by value.
  ///
  /// A language link says which of the server's language tags a value the
  /// DataGateway uses for a language, such as "Czech", stands for. An interview
  /// or an import writes one for each value it meets, and an admin settles the
  /// ones the server could not match on its own.
  ///
  /// With no [statuses], the server lists the links waiting on a review:
  /// [LanguageLinkStatus.pending] and [LanguageLinkStatus.unresolved]. Name
  /// other statuses to list those instead. An empty set throws
  /// [ArgumentError], since the server answers one with a 400: pass null for
  /// the default. [limit] is in `1..maxPageSize`.
  ///
  /// Throws [DataGatewayNotFoundException] when the DataGateway is gone.
  Future<PaginatedResult<LanguageLink>> fetchLanguageLinks(
    String id, {
    Set<LanguageLinkStatus>? statuses,
    int page = 1,
    int limit = languageLinkPageSize,
  });

  /// Links the language link [linkId] to the tag [tagId], whatever its status,
  /// and returns it as it now stands.
  ///
  /// Throws [DataGatewayPermanentException] with status 400 when there is no
  /// such tag, and [DataGatewayNotFoundException] when the DataGateway or the
  /// link is gone.
  Future<LanguageLink> linkLanguageLink(String id, String linkId, String tagId);

  /// Dismisses the language link [linkId], whatever its status, and returns it
  /// as it now stands. It loses any tag it had, and interviews and imports
  /// leave an ignored link alone.
  ///
  /// Throws [DataGatewayNotFoundException] when the DataGateway or the link is
  /// gone.
  Future<LanguageLink> ignoreLanguageLink(String id, String linkId);

  /// Accepts the pending language link [linkId]: the server adds its language
  /// and tag when they are missing, links it to the tag, and returns it as it
  /// now stands.
  ///
  /// Throws [DataGatewayConflictException] when the link is not pending, or
  /// names no language the server has registered, and
  /// [DataGatewayNotFoundException] when the DataGateway or the link is gone.
  Future<LanguageLink> acceptLanguageLink(String id, String linkId);

  /// One page of the server's language tags, for picking one to link to.
  ///
  /// Flattened to one item per tag: languages alphabetical by name, and each
  /// language's tags by tag. [PaginatedResult.meta] is the languages' paging,
  /// because that is what the server pages. A language with no tags adds no
  /// item, so a page can hold none and still have more behind it: follow
  /// [PaginationMeta.hasMore], not the item count.
  ///
  /// [name] filters the languages by their own name, case-insensitively and by
  /// part, so a match brings all of that language's tags. It is trimmed, and a
  /// blank one filters nothing. [limit] is in `1..languageTagPageSize`.
  Future<PaginatedResult<LanguageTagRef>> fetchLanguageTags({
    String? name,
    int page = 1,
    int limit = languageTagPageSize,
  });
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

/// The named DataGateway does not exist, or was deleted. On a language link
/// action it can also mean the link is not one of that DataGateway's.
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

/// The request conflicts with the DataGateway, or a language link of it, as it
/// stands, such as an interview of a DataGateway that is disabled or accepting
/// a link that is not pending: a 409 from the API on a route where it is not a
/// name clash.
final class DataGatewayConflictException extends DataGatewayRemoteException {
  const DataGatewayConflictException(
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

/// An interview got no answer in time, and the server may still be working on
/// it.
///
/// Unlike a [DataGatewayTransientException], trying again is not the answer:
/// the interview may have started and may yet finish, so read the row again
/// before sending it twice.
final class DataGatewayTimedOutException extends DataGatewayRemoteException {
  const DataGatewayTimedOutException(
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
