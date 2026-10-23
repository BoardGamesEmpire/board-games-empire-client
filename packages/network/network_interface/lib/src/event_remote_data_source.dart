import 'package:models/domain.dart';

import 'paginated_result.dart';

/// Remote data source for the events the signed-in user attends (#496).
///
/// Read-only. The event hydrate pages through [fetchEvents] to cache the
/// user's events, and [fetchEvent] reads one event whole, roster included,
/// which the list does not carry. Creating an event is #499, and answering an
/// invitation or voting is #527.
///
/// Implementations run over a **per-server** authenticated transport, like
/// [HouseholdRemoteDataSource]: the injected client carries the base URL and
/// the session, and this interface adds no auth handling of its own.
///
/// ## Wire contract
///
/// Backend `libs/api/event`, all under the `api` global prefix:
///
/// | Method | Path | Body |
/// |---|---|---|
/// | [fetchEvents] | `GET /api/events` | `{ events: [...], pagination }` |
/// | [fetchEvent] | `GET /api/events/:id` | `{ event }` |
///
/// The two reads do not return the same parts, and an [EventSnapshot] records
/// which it got:
///
/// - **The list** serves each event with its `occurrences`, always a list, and
///   its `policy`, an object or null. No row carries a roster, so every
///   snapshot from [fetchEvents] has `attendees: null`. That says nothing about
///   who is on the event.
/// - **The detail** serves the event with its `occurrences`, `attendees` and
///   `policy`. Each of the three is read under its own permission
///   (backend#560): a caller who may not read the roster is served
///   `attendees: []`, and one who may not read the policy `null`. So the
///   snapshot from [fetchEvent] always has a roster, and an empty one is not
///   proof that nobody is on the event.
///
/// Both reads serve every occurrence of an event, unbounded until backend#404.
///
/// The rows carry columns the models have no home for: the cancellation,
/// deletion and recurrence fields, and the email address of a guest with no
/// account. Implementations read none of them (#496).
///
/// ## What the list holds
///
/// `GET /api/events` lists the events the caller holds an attendee row for,
/// hosts included, whatever the row's RSVP status, so an invitation the caller
/// has not answered is listed too (backend#512). A row a host removed does not
/// count (backend#551), and soft-deleted events are not listed. The order is
/// `createdAt desc, id desc`.
///
/// That is narrower than what the caller may read. An event the list does not
/// show stays readable by id for whoever could read it before, so an event
/// missing from the list is not necessarily one that [fetchEvent] answers 404
/// for.
///
/// ## Who may call what
///
/// Both reads need the caller's `read:event` permission. A caller without it
/// is refused with a 403 carrying the API's error envelope, which surfaces as
/// [EventRemoteForbiddenException]. Past that gate the caller's standing
/// decides what each read returns rather than whether it is allowed: the
/// events the caller attends, and the parts of one the caller may read.
///
/// An event that does not exist, one that was deleted and one the caller may
/// not read all answer the same 404, so [EventRemoteNotFoundException] does not
/// say which.
///
/// ## Values this client does not know
///
/// A newer server can send an enum name this client has no value for: a status
/// backend#795 adds, or a role a deployment defines. It reads as that enum's
/// `unknown`, and the event stays readable. It is not a failure.
///
/// ## Failure classification
///
/// Every transport failure is wrapped as an [EventRemoteException]; callers
/// never see a raw transport error.
///
/// - [EventRemoteForbiddenException]: a 403 carrying the API's error envelope.
/// - [EventRemoteNotFoundException]: a 404 carrying the envelope, from
///   [fetchEvent]. The event is gone, or the caller may not read it.
/// - [EventRemotePermanentException]: any other 4xx the transient rule below
///   leaves out (a 400 for a value the server rejects, and a 409 that is not
///   asking for a retry), and a 2xx whose body cannot be read as the contract
///   above, such as a detail with no roster.
/// - [EventRemoteTransientException]: no response at all, 401, 407, 408, 429,
///   every 5xx, a 403 or 404 without the envelope (a proxy answered, not the
///   API), a 404 from [fetchEvents] even with it (a list route is never absent,
///   so the route is not deployed), a 409 saying `retryable: true` (a deadlock
///   the server asks the caller to retry), and a 2xx body this device could not
///   decode at all.
///
/// The envelope requirement is the household and collection rule (#350, #365,
/// #253): only the application's own answer licenses a conclusion about the
/// caller's role or about a row.
///
/// A call that cannot produce a valid request throws [ArgumentError]
/// unwrapped: an out-of-range page or limit, or an empty id.
abstract class EventRemoteDataSource {
  /// The backend's `limit` ceiling (`DEFAULT_MAX_PAGE_SIZE`). A larger limit is
  /// a 400, not clamped.
  static const int maxPageSize = 100;

  /// `GET /api/events`: one page of the events the caller attends, newest
  /// first. Each snapshot has `attendees: null`, because the list carries no
  /// roster.
  ///
  /// Follow [PaginationMeta.hasMore] to the end of the list, never by inferring
  /// the end from a page shorter than [limit]. [page] is 1-based and [limit] is
  /// in `1..maxPageSize`.
  ///
  /// A walk across pages is not one snapshot: an event that leaves the list
  /// between two requests shifts the rest up and can carry one past the
  /// boundary unseen. Only a first page with `hasMore: false` is complete.
  Future<PaginatedResult<EventSnapshot>> fetchEvents({
    int page = 1,
    int limit = maxPageSize,
  });

  /// `GET /api/events/:id`: one event with its occurrences, policy and roster.
  /// Its `attendees` is never null.
  ///
  /// Throws [EventRemoteNotFoundException] when the event is gone or the caller
  /// may not read it.
  Future<EventSnapshot> fetchEvent(String id);
}

/// Base class for every event remote failure.
sealed class EventRemoteException implements Exception {
  const EventRemoteException(this.message, {this.statusCode, this.cause});

  final String message;

  /// The HTTP status, when the failure carried a response.
  final int? statusCode;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() =>
      '$runtimeType(message: $message, statusCode: $statusCode)';
}

/// The event is gone, or the caller may not read it: a 404 from the API itself.
final class EventRemoteNotFoundException extends EventRemoteException {
  const EventRemoteNotFoundException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The caller may not read events: a 403 from the API itself.
final class EventRemoteForbiddenException extends EventRemoteException {
  const EventRemoteForbiddenException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The server refused the request, and sending it again will not change that.
final class EventRemotePermanentException extends EventRemoteException {
  const EventRemotePermanentException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}

/// The request did not get an answer from the API that says anything about
/// it. Trying again later may work.
final class EventRemoteTransientException extends EventRemoteException {
  const EventRemoteTransientException(
    super.message, {
    super.statusCode,
    super.cause,
  });
}
