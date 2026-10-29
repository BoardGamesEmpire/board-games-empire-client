import 'package:models/domain.dart';

import 'paginated_result.dart';

/// What [EventRemoteDataSource.createEvent] got back: the event the server
/// holds, and whether it is deleted.
///
/// [deletedAt] is null for a live event. A repeat of a create whose event was
/// deleted since returns that event with the time it was deleted (#499).
typedef CreatedEvent = ({EventSnapshot snapshot, DateTime? deletedAt});

/// Remote data source for the events the signed-in user attends (#496), for
/// creating one (#499) and for deleting one (#501).
///
/// The event hydrate pages through [fetchEvents] to cache the user's events,
/// and [fetchEvent] reads one event whole, roster included, which the list
/// does not carry. [createEvent] sends a new event and [deleteEvent] removes
/// one. Answering an invitation or voting is #527.
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
/// | [createEvent] | `POST /api/events` | `{ message, event }` |
/// | [deleteEvent] | `DELETE /api/events/:id` | `{ message, event }`, not read |
/// | [addOccurrence] | `POST /api/events/:id/occurrences` | `{ message, occurrence }` |
/// | [updateOccurrence] | `PATCH /api/events/:id/occurrences/:oid` | `{ message, occurrence }` |
/// | [confirmOccurrence] | `POST /api/events/:id/occurrences/:oid/confirm` | `{ message, occurrence }` |
/// | [declineOccurrence] | `POST /api/events/:id/occurrences/:oid/decline` | `{ message, occurrence }` |
/// | [cancelOccurrence] | `POST /api/events/:id/occurrences/:oid/cancel` | `{ message, occurrence }` |
/// | [removeOccurrence] | `DELETE /api/events/:id/occurrences/:oid` | `{ message, ... }`, not read |
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
///   [fetchEvent] or [deleteEvent]. From [fetchEvent] the event is gone, or
///   the caller may not read it. From [deleteEvent] no live event has the id.
/// - [EventCreateRefusedException]: a 403 or 404 carrying the envelope, from
///   [createEvent], which says the API refused that create (below).
/// - [EventWriteRefusedException]: a 403 carrying the envelope, from
///   [deleteEvent] and from each date write below, which says the API refused
///   that write to an existing event (below).
/// - [EventWriteConflictException]: a 400 carrying the envelope with one
///   message, from a write to an existing event's dates (below).
/// - [EventRemotePermanentException]: any other 4xx the transient rule below
///   leaves out (a 400 for a value the server rejects, a date write's
///   included, and a 409 that is not
///   asking for a retry), and a 2xx whose body cannot be read as the contract
///   above, such as a detail or a create with no roster.
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
/// ### The create's refusals
///
/// [createEvent] is sent from a queue, so what matters is whether the same
/// request will be answered the same way. A 403 or 404 carrying the envelope
/// is the API's answer about this request: the caller has no grant to create
/// in the household, the household does not exist, the server's or an
/// invitee's settings refuse an invitee, or an invitee does not exist. Sending
/// it again changes nothing, so it surfaces as [EventCreateRefusedException],
/// not as the reads' [EventRemoteForbiddenException] (the caller may not read
/// events) or [EventRemoteNotFoundException] (the event is gone). Without the
/// envelope a 403 or 404 stays transient, as everywhere else.
///
/// An enveloped 404 is read as a refusal even though Nest answers an unrouted
/// path with the same envelope, so a server without the route is misread as
/// refusing. That is accepted: a refusal is parked, which is bounded and can
/// be discarded by hand, where a transient failure would be retried forever.
///
/// ### The delete's answers
///
/// [deleteEvent] names one event, and a 404 carrying the envelope says the
/// server has no live event with that id. It looks among every live event,
/// not only those the caller may read, so a caller who may not delete a live
/// event is refused (below) rather than told it is gone. A second DELETE of
/// one event answers 404 too, so a caller whose first answer was lost reads
/// the repeat as gone.
///
/// Its body is not read, so any 2xx is a delete, and neither rule above for a
/// 2xx body this client could not read applies to it.
///
/// A 403 carrying the envelope is the API refusing this write, and it is
/// refused again on every attempt, so it surfaces as
/// [EventWriteRefusedException], not as the reads'
/// [EventRemoteForbiddenException] (the caller may not read events). Without
/// the envelope a 403 or 404 stays transient, as everywhere else.
///
/// ### The date writes' answers
///
/// The six date calls name one date of one event, and each is a write to it
/// (#506). A 404 carrying the envelope says the event or the date is gone, and
/// a 403 carrying it is the API refusing the write
/// ([EventWriteRefusedException]). A 400 carrying it with one message is
/// [EventWriteConflictException]: the server judged the write against the row
/// as it stands now, and said no. That can be a date that moved since the
/// caller read it, a retry of a write that already landed (backend#901), a
/// cancelled event, or a Fixed event's second date. The same request can be
/// accepted after a re-read, so unlike [EventRemotePermanentException] it
/// says the caller's picture is stale. A 400 without the envelope stays
/// permanent, and so does the validation pipe's, whose message lists each
/// value it refused: the same request is refused again. [deleteEvent] shares the classification, but the server never
/// answers it 400.
///
/// The status routes answer 201 (backend#620), and any 2xx is a success.
///
/// A call that cannot produce a valid request throws [ArgumentError]
/// unwrapped: an out-of-range page or limit, an empty id, an update that
/// changes nothing, a cancel reason past [maxCancelReasonLength], or a create
/// that could not be sent (what [createEvent] never sends).
abstract class EventRemoteDataSource {
  /// The backend's `limit` ceiling (`DEFAULT_MAX_PAGE_SIZE`). A larger limit is
  /// a 400, not clamped.
  static const int maxPageSize = 100;

  /// The server's length ceiling for [createEvent]'s `clientRequestId`,
  /// measured after it trims the key. A longer key is a 400.
  static const int maxClientRequestIdLength = 128;

  /// The server's length ceiling for [cancelOccurrence]'s `reason`, in code
  /// points, as its `MaxLength` counts them. A longer one is a 400, which is
  /// permanent.
  static const int maxCancelReasonLength = 1000;

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

  /// `POST /api/events`: creates the event [draft] describes, with the caller
  /// as its host, and returns it with its occurrences, policy and roster.
  ///
  /// Wire contract (backend `libs/api/event`): `POST /api/events` with the
  /// draft's fields, each occurrence's `sortOrder` its position in the draft,
  /// and [clientRequestId] → 201 `{ message, event }`. A field the draft leaves
  /// null is left out, so the server's default applies. Times go out in UTC.
  ///
  /// The returned snapshot's `attendees` is never null, but the create's roster
  /// embeds each attendee's role and not the `user` the detail read embeds, so
  /// the names on it are null. The caller who needs them reads the event.
  ///
  /// ### [clientRequestId] makes the create idempotent
  ///
  /// The server keeps at most one event per user per key (backend#252). A
  /// create carrying a key it has already seen creates nothing, and notifies
  /// no one again: it returns the event the first one made, answered 201
  /// again, **ignoring the repeat's payload**. That holds if the event has
  /// since been deleted, and [CreatedEvent.deletedAt] then says when.
  ///
  /// So pass the queued create's `localId`, the same value on every attempt at
  /// one create: then a response lost in transit cannot turn the retry into a
  /// second event. A key minted per attempt defeats the guarantee without
  /// failing anything.
  ///
  /// A repeat reads the event's parts as the caller may read them now, as
  /// [fetchEvent] does. A creator who has lost read on the event since gets
  /// the event, an empty roster and no policy.
  ///
  /// ### What is never sent
  ///
  /// Each of these is a 400, which is permanent and parks a queued create on
  /// its first attempt, so it throws [ArgumentError] before the request: a
  /// [clientRequestId] that is empty or longer than [maxClientRequestIdLength]
  /// after trimming, more than [EventDraft.maxInvitees] invitees, and an
  /// `unknown` enum value anywhere in [draft], which has no wire name. Like the
  /// reads' paging checks, that error is not an [EventRemoteException].
  ///
  /// Throws [EventCreateRefusedException] when the API refuses the create, and
  /// otherwise [EventRemoteException] per the class doc.
  Future<CreatedEvent> createEvent(
    EventDraft draft, {
    required String clientRequestId,
  });

  /// `DELETE /api/events/:id`: deletes the event, and completes once the
  /// server has. Answers 200 `{ message, event }`, and the body is not read: a
  /// delete is whole once the status says so, so one this client could not map
  /// is still one that happened.
  ///
  /// Throws [EventRemoteNotFoundException] when the server has no live event
  /// with this id. That is also what a second DELETE of one event answers, so
  /// a caller cannot tell its own earlier delete from someone else's.
  /// Throws [EventWriteRefusedException] when the API refuses the delete, such
  /// as for a caller who may not delete this event, and otherwise
  /// [EventRemoteException] per the class doc.
  ///
  /// An empty [id] throws [ArgumentError] before the request, as for
  /// [fetchEvent].
  Future<void> deleteEvent(String id);

  /// `POST /api/events/:eventId/occurrences`: adds [draft] as a date of the
  /// event, at position [sortOrder], and returns it as the server holds it.
  ///
  /// Answers 201 `{ message, occurrence }`. A field the draft leaves null is
  /// left out, and times go out in UTC. No status is sent: the server decides
  /// it from the event.
  ///
  /// A 400 ([EventWriteConflictException]) can mean a cancelled event, or a
  /// Fixed event's second date. A retried add creates a second date
  /// (backend#902), so a caller whose first answer was lost reads the event
  /// before it adds again.
  ///
  /// Throws [ArgumentError] before the request for an empty id, and otherwise
  /// [EventRemoteException] per the class doc.
  Future<EventOccurrence> addOccurrence(
    String eventId,
    EventOccurrenceDraft draft, {
    required int sortOrder,
  });

  /// `PATCH /api/events/:eventId/occurrences/:occurrenceId`: changes the date
  /// as [update] says, and returns it as the server holds it.
  ///
  /// Only what [update] names is sent, and a cleared field goes as `null`.
  /// Throws [ArgumentError] before the request for an empty id or an
  /// [OccurrenceUpdate.isEmpty] one.
  ///
  /// A 400 ([EventWriteConflictException]) can mean a date that moved since it
  /// was read, such as one cancelled elsewhere.
  Future<EventOccurrence> updateOccurrence(
    String eventId,
    String occurrenceId,
    OccurrenceUpdate update,
  );

  /// `POST /api/events/:eventId/occurrences/:occurrenceId/confirm`: confirms a
  /// proposed date, and returns it. Answers 201.
  ///
  /// A 400 ([EventWriteConflictException]) can mean the date is no longer
  /// proposed, or a retry of a confirm that landed (backend#901).
  Future<EventOccurrence> confirmOccurrence(
    String eventId,
    String occurrenceId,
  );

  /// `POST /api/events/:eventId/occurrences/:occurrenceId/decline`: declines a
  /// proposed date, and returns it. Answers 201.
  ///
  /// A 400 ([EventWriteConflictException]) reads as for [confirmOccurrence].
  Future<EventOccurrence> declineOccurrence(
    String eventId,
    String occurrenceId,
  );

  /// `POST /api/events/:eventId/occurrences/:occurrenceId/cancel`: cancels a
  /// date, and returns it with its [EventOccurrence.cancelReason]. Answers 201.
  ///
  /// [reason] is trimmed, and one that is empty after trimming is not sent: the
  /// body is `{}`. A reason longer than [maxCancelReasonLength] after trimming
  /// throws [ArgumentError] before the request, because the server's 400 for it
  /// is permanent.
  ///
  /// A 400 ([EventWriteConflictException]) can mean the date was cancelled
  /// elsewhere, or a retry of a cancel that landed (backend#901).
  Future<EventOccurrence> cancelOccurrence(
    String eventId,
    String occurrenceId, {
    String? reason,
  });

  /// `DELETE /api/events/:eventId/occurrences/:occurrenceId`: removes a date,
  /// and completes once the server has. The body is not read, so any 2xx is a
  /// removal.
  ///
  /// A Confirmed date is cancelled first, so a 400
  /// ([EventWriteConflictException]) can mean it is Confirmed.
  Future<void> removeOccurrence(String eventId, String occurrenceId);
}

/// A change to one date of an event, for
/// [EventRemoteDataSource.updateOccurrence] (#506).
///
/// A field left out stays as it is. To clear [label], [endDate] or [location]
/// set its `clear` flag instead of a value: the PATCH can't send both, so a
/// value with its own flag throws [ArgumentError]. A blank [label] or
/// [location] throws too, because the server rejects it. The start date can't
/// be cleared.
///
/// Equal by its fields, as the bloc event carrying it is compared.
final class OccurrenceUpdate {
  OccurrenceUpdate({
    String? label,
    this.clearLabel = false,
    this.startDate,
    this.endDate,
    this.clearEndDate = false,
    String? location,
    this.clearLocation = false,
  }) : label = _trimmed(label, 'label', clearLabel),
       location = _trimmed(location, 'location', clearLocation) {
    if (endDate != null && clearEndDate) {
      throw ArgumentError.value(
        endDate,
        'endDate',
        'cannot be given with clearEndDate',
      );
    }
  }

  /// The new label, trimmed.
  final String? label;
  final bool clearLabel;
  final DateTime? startDate;
  final DateTime? endDate;
  final bool clearEndDate;

  /// The new place, trimmed.
  final String? location;
  final bool clearLocation;

  @override
  bool operator ==(Object other) =>
      other is OccurrenceUpdate &&
      other.label == label &&
      other.clearLabel == clearLabel &&
      other.startDate == startDate &&
      other.endDate == endDate &&
      other.clearEndDate == clearEndDate &&
      other.location == location &&
      other.clearLocation == clearLocation;

  @override
  int get hashCode => Object.hash(
    label,
    clearLabel,
    startDate,
    endDate,
    clearEndDate,
    location,
    clearLocation,
  );

  /// Whether this changes nothing, which the remote refuses to send.
  bool get isEmpty =>
      label == null &&
      !clearLabel &&
      startDate == null &&
      endDate == null &&
      !clearEndDate &&
      location == null &&
      !clearLocation;

  static String? _trimmed(String? value, String name, bool clear) {
    if (value == null) return null;
    if (clear) {
      throw ArgumentError.value(value, name, 'cannot be given with its clear');
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(value, name, 'must not be blank');
    }
    return trimmed;
  }
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

/// The API refused this create, and the same request will be refused again: a
/// 403 or 404 carrying its error envelope (#499).
///
/// A missing household grant, a refused invitee, an unknown household and an
/// unknown invitee all read this way. It is not [EventRemoteForbiddenException]
/// or [EventRemoteNotFoundException], which are about reading events.
final class EventCreateRefusedException extends EventRemoteException {
  const EventCreateRefusedException(
    super.message, {
    super.statusCode,
    super.cause,
    this.apiMessage,
  });

  /// The `message` of the API's error envelope, when it is a string. The
  /// server's 404 for an invitee it has no account for names their id there
  /// (#499), where [message] is this client's own and names no one.
  ///
  /// The server translates it into the request's locale, so it is for
  /// finding an id it names, never for showing.
  final String? apiMessage;
}

/// The API refused this write to an existing event, and the same request will
/// be refused again: a 403 carrying its error envelope (#501).
///
/// Not [EventRemoteForbiddenException], which is about reading events.
final class EventWriteRefusedException extends EventRemoteException {
  const EventWriteRefusedException(
    super.message, {
    super.statusCode,
    super.cause,
    this.apiMessage,
  });

  /// The `message` of the API's error envelope, when it is a string, where
  /// [message] is this client's own.
  ///
  /// The server translates it into the request's locale, so it is for finding
  /// an id it names, never for showing.
  final String? apiMessage;
}

/// A 400 carrying the API's envelope with one message, from a write to an
/// existing event or date: the server judged it against the row as it stands
/// now (#506). The validation pipe's 400 lists its messages, and is
/// [EventRemotePermanentException].
///
/// A date that moved, a retry of a write that landed, a cancelled event and a
/// Fixed event's second date all read this way. Not
/// [EventRemotePermanentException]: a re-read can change the answer.
final class EventWriteConflictException extends EventRemoteException {
  const EventWriteConflictException(
    super.message, {
    super.statusCode,
    super.cause,
    this.apiMessage,
  });

  /// The `message` of the API's error envelope, when it is a string, where
  /// [message] is this client's own.
  ///
  /// The server translates it into the request's locale, so it is for finding
  /// an id it names, never for showing.
  final String? apiMessage;
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
