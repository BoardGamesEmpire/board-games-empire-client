import 'dart:async';

import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// What the hydrate asked for in one list request.
typedef EventListRequest = ({int page, int limit});

/// What a create sent: the draft and the key it was sent under (#499).
typedef EventCreateRequest = ({EventDraft draft, String clientRequestId});

/// What a date write sent (#506): its `call`, one of `add`, `update`,
/// `confirm`, `decline`, `cancel` and `remove`, the ids it named, and what
/// it carried. An add names no date.
typedef EventDateRequest = ({
  String call,
  String eventId,
  String? occurrenceId,
  EventOccurrenceDraft? draft,
  int? sortOrder,
  OccurrenceUpdate? update,
  String? reason,
});

/// What an event status write sent (#502): its `call`, one of `cancel`,
/// `reopen`, `archive` and `unarchive`, the event it named, and the reason a
/// cancel carried.
typedef EventStatusRequest = ({String call, String id, String? reason});

/// What a vote sent (#507): the event, the date, and the answer.
typedef EventVoteRequest = ({
  String eventId,
  String occurrenceId,
  AvailabilityResponse response,
});

/// What an RSVP sent (#508): the event, the attendee, the answer, and the note
/// (null when left out, an empty string when clearing it).
typedef RsvpRequest = ({
  String eventId,
  String attendeeId,
  EventParticipationStatus status,
  String? notes,
});

/// One whole page of [rows], as a browse read answers (#613).
PaginatedResult<EventSnapshot> browsePage(List<EventSnapshot> rows) =>
    PaginatedResult(
      items: rows,
      meta: PaginationMeta(
        page: 1,
        limit: 3,
        total: rows.length,
        totalPages: 1,
        hasMore: false,
      ),
    );

/// An event remote that answers list requests from [respond], detail requests
/// from [detail], creates from [created], deletes from [deleted], date writes
/// from [dateWritten], votes from [voted] and poll reads from [summary], and
/// records each one. A request it has no answer for throws, as does anything
/// else.
class FakeEventRemote implements EventRemoteDataSource {
  FakeEventRemote(
    FutureOr<PaginatedResult<EventSnapshot>> Function(EventListRequest request)
    this.respond, {
    this.created = _noCreate,
    this.deleted = _noDelete,
    this.dateWritten = _noDateWrite,
    this.voted = _noVote,
    this.summary = _noSummary,
    this.statusWritten = _noStatusWrite,
    this.rsvp = _noRsvp,
  }) : detail = null;

  /// Serves scripted [pages], page N from `pages[N - 1]`, and throws [error]
  /// for [failOnPage] instead.
  FakeEventRemote.pages(
    List<PaginatedResult<EventSnapshot>> pages, {
    int? failOnPage,
    Object error = const EventRemoteTransientException('offline'),
    this.created = _noCreate,
    this.deleted = _noDelete,
    this.dateWritten = _noDateWrite,
    this.voted = _noVote,
    this.summary = _noSummary,
    this.statusWritten = _noStatusWrite,
    this.rsvp = _noRsvp,
  }) : respond = ((request) {
         // The fake throws what a test hands it: an Exception or an Error.
         // ignore: only_throw_errors
         if (request.page == failOnPage) throw error;
         return pages[request.page - 1];
       }),
       detail = null;

  /// Answers detail reads from [detail], for the detail screen (#498),
  /// which makes no list read.
  FakeEventRemote.detail(
    FutureOr<EventSnapshot> Function(String id) this.detail, {
    this.created = _noCreate,
    this.deleted = _noDelete,
    this.dateWritten = _noDateWrite,
    this.voted = _noVote,
    this.summary = _noSummary,
    this.statusWritten = _noStatusWrite,
    this.rsvp = _noRsvp,
  }) : respond = null;

  static Never _noCreate(EventDraft draft, String clientRequestId) =>
      throw UnimplementedError('createEvent is not faked');

  static Never _noDelete(String id) =>
      throw UnimplementedError('deleteEvent is not faked');

  static Never _noDateWrite(EventDateRequest request) =>
      throw UnimplementedError('the date ${request.call} is not faked');

  static Never _noStatusWrite(EventStatusRequest request) =>
      throw UnimplementedError('the event ${request.call} is not faked');

  static Never _noRsvp(RsvpRequest request) =>
      throw UnimplementedError('updateAttendeeStatus is not faked');

  static Never _noVote(EventVoteRequest request) =>
      throw UnimplementedError('submitAvailability is not faked');

  static Never _noSummary(String eventId) =>
      throw UnimplementedError('fetchAvailabilitySummary is not faked');

  final FutureOr<PaginatedResult<EventSnapshot>> Function(
    EventListRequest request,
  )?
  respond;

  final FutureOr<EventSnapshot> Function(String id)? detail;

  /// Answers each create, which throws unless a test supplies one.
  final FutureOr<CreatedEvent> Function(
    EventDraft draft,
    String clientRequestId,
  )
  created;

  /// Answers each delete, which throws unless a test supplies one.
  final FutureOr<void> Function(String id) deleted;

  /// Answers each date write with the date as the server holds it after,
  /// which throws unless a test supplies one. A remove's answer isn't read,
  /// so it may be null.
  final FutureOr<EventOccurrence?> Function(EventDateRequest request)
  dateWritten;

  /// Answers each vote with the vote as the server holds it, which throws
  /// unless a test supplies one. A future the test completes later holds the
  /// vote in flight.
  final FutureOr<AvailabilityVote> Function(EventVoteRequest request) voted;

  /// Answers each poll read of the event it names, which throws unless a test
  /// supplies one.
  final FutureOr<AvailabilitySummary> Function(String eventId) summary;

  /// Answers each event status write with the event as the server holds it
  /// after, or throws what a test supplies. It throws unless a test supplies
  /// one (#502).
  final FutureOr<Event> Function(EventStatusRequest request) statusWritten;

  /// Answers each RSVP with the attendee as the server holds it after, which
  /// throws unless a test supplies one (#508).
  final FutureOr<EventAttendee> Function(RsvpRequest request) rsvp;

  /// Each RSVP, in order, recorded before it is answered.
  final List<RsvpRequest> rsvps = [];

  final List<EventListRequest> requests = [];

  /// The `includeArchived` of each list read, in order, beside [requests].
  final List<bool> includeArchivedRequests = [];

  /// Each event status write, in order, recorded before it is answered.
  final List<EventStatusRequest> statusRequests = [];

  /// Answers each browse read, which throws unless a test supplies one (#613).
  FutureOr<PaginatedResult<EventSnapshot>> Function(EventListRequest request)?
  browse;

  /// Each browse read, in order, recorded before it is answered.
  final List<EventListRequest> browseRequests = [];

  /// Scripted household pages, keyed by household id and served in page order
  /// (#503).
  final Map<String, List<PaginatedResult<EventSnapshot>>> householdPages = {};

  /// Each household read, in order, recorded before it is answered.
  final List<({String householdId, int page, int limit})> householdRequests =
      [];

  /// Thrown by each household read when set.
  Object? householdError;

  /// The id of each detail read, in order.
  final List<String> detailRequests = [];

  /// Each create, in order, recorded before it is answered.
  final List<EventCreateRequest> createRequests = [];

  /// The id of each delete, in order, recorded before it is answered.
  final List<String> deleteRequests = [];

  /// Each date write, in order, recorded before it is answered.
  final List<EventDateRequest> dateRequests = [];

  /// Each vote, in order, recorded before it is answered.
  final List<EventVoteRequest> voteRequests = [];

  /// The event id of each poll read, in order, recorded before it is
  /// answered.
  final List<String> summaryRequests = [];

  @override
  Future<PaginatedResult<EventSnapshot>> fetchEvents({
    int page = 1,
    int limit = EventRemoteDataSource.maxPageSize,
    bool includeArchived = false,
  }) async {
    final respond = this.respond;
    if (respond == null) {
      throw UnimplementedError('fetchEvents is not in a detail read');
    }
    final request = (page: page, limit: limit);
    requests.add(request);
    includeArchivedRequests.add(includeArchived);
    return respond(request);
  }

  @override
  Future<PaginatedResult<EventSnapshot>> browseEvents({
    int page = 1,
    int limit = EventRemoteDataSource.maxPageSize,
  }) async {
    final request = (page: page, limit: limit);
    browseRequests.add(request);
    final browse = this.browse;
    if (browse == null) {
      throw UnimplementedError('browseEvents is not faked');
    }
    return browse(request);
  }

  @override
  Future<PaginatedResult<EventSnapshot>> fetchHouseholdEvents(
    String householdId, {
    int page = 1,
    int limit = EventRemoteDataSource.maxPageSize,
  }) async {
    householdRequests.add((householdId: householdId, page: page, limit: limit));
    final error = householdError;
    // The fake throws what a test hands it: an Exception or an Error.
    // ignore: only_throw_errors
    if (error != null) throw error;
    final pages = householdPages[householdId];
    if (pages == null || page < 1 || page > pages.length) {
      throw UnimplementedError(
        'household $householdId page $page is not faked',
      );
    }
    return pages[page - 1];
  }

  @override
  Future<EventSnapshot> fetchEvent(String id) async {
    final detail = this.detail;
    if (detail == null) {
      throw UnimplementedError('fetchEvent is not in a hydrate');
    }
    detailRequests.add(id);
    return detail(id);
  }

  @override
  Future<CreatedEvent> createEvent(
    EventDraft draft, {
    required String clientRequestId,
  }) async {
    createRequests.add((draft: draft, clientRequestId: clientRequestId));
    return created(draft, clientRequestId);
  }

  @override
  Future<void> deleteEvent(String id) async {
    deleteRequests.add(id);
    return deleted(id);
  }

  @override
  Future<Event> cancelEvent(String id, {String? reason}) =>
      _writeStatus('cancel', id, reason: reason);

  @override
  Future<Event> reopenEvent(String id) => _writeStatus('reopen', id);

  @override
  Future<Event> archiveEvent(String id) => _writeStatus('archive', id);

  @override
  Future<Event> unarchiveEvent(String id) => _writeStatus('unarchive', id);

  /// Records one event status write, then answers it from [statusWritten].
  Future<Event> _writeStatus(String call, String id, {String? reason}) async {
    final request = (call: call, id: id, reason: reason);
    statusRequests.add(request);
    return statusWritten(request);
  }

  @override
  Future<EventOccurrence> addOccurrence(
    String eventId,
    EventOccurrenceDraft draft, {
    required int sortOrder,
  }) async => _dated(
    'add',
    await _writeDate('add', eventId, draft: draft, sortOrder: sortOrder),
  );

  @override
  Future<EventOccurrence> updateOccurrence(
    String eventId,
    String occurrenceId,
    OccurrenceUpdate update,
  ) async => _dated(
    'update',
    await _writeDate(
      'update',
      eventId,
      occurrenceId: occurrenceId,
      update: update,
    ),
  );

  @override
  Future<EventOccurrence> confirmOccurrence(
    String eventId,
    String occurrenceId,
  ) async => _dated(
    'confirm',
    await _writeDate('confirm', eventId, occurrenceId: occurrenceId),
  );

  @override
  Future<EventOccurrence> declineOccurrence(
    String eventId,
    String occurrenceId,
  ) async => _dated(
    'decline',
    await _writeDate('decline', eventId, occurrenceId: occurrenceId),
  );

  @override
  Future<EventOccurrence> cancelOccurrence(
    String eventId,
    String occurrenceId, {
    String? reason,
  }) async => _dated(
    'cancel',
    await _writeDate(
      'cancel',
      eventId,
      occurrenceId: occurrenceId,
      reason: reason,
    ),
  );

  @override
  Future<void> removeOccurrence(String eventId, String occurrenceId) async {
    await _writeDate('remove', eventId, occurrenceId: occurrenceId);
  }

  /// Records one date write, then answers it from [dateWritten].
  Future<EventOccurrence?> _writeDate(
    String call,
    String eventId, {
    String? occurrenceId,
    EventOccurrenceDraft? draft,
    int? sortOrder,
    OccurrenceUpdate? update,
    String? reason,
  }) async {
    final request = (
      call: call,
      eventId: eventId,
      occurrenceId: occurrenceId,
      draft: draft,
      sortOrder: sortOrder,
      update: update,
      reason: reason,
    );
    dateRequests.add(request);
    return dateWritten(request);
  }

  @override
  Future<AvailabilityVote> submitAvailability(
    String eventId,
    String occurrenceId,
    AvailabilityResponse response,
  ) async {
    final request = (
      eventId: eventId,
      occurrenceId: occurrenceId,
      response: response,
    );
    voteRequests.add(request);
    return voted(request);
  }

  @override
  Future<EventAttendee> updateAttendeeStatus(
    String eventId,
    String attendeeId,
    EventParticipationStatus status, {
    String? notes,
  }) async {
    final request = (
      eventId: eventId,
      attendeeId: attendeeId,
      status: status,
      notes: notes,
    );
    rsvps.add(request);
    return rsvp(request);
  }

  @override
  Future<AvailabilitySummary> fetchAvailabilitySummary(String eventId) async {
    summaryRequests.add(eventId);
    return summary(eventId);
  }

  /// [answer], which a [call] other than a remove must have.
  static EventOccurrence _dated(String call, EventOccurrence? answer) =>
      answer ?? (throw StateError('the fake answered a date $call with none'));

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}
