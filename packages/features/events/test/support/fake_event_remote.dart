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

/// An event remote that answers list requests from [respond], detail requests
/// from [detail], creates from [created], deletes from [deleted] and date
/// writes from [dateWritten], and records each one. A request it has no
/// answer for throws, as does anything else.
class FakeEventRemote implements EventRemoteDataSource {
  FakeEventRemote(
    FutureOr<PaginatedResult<EventSnapshot>> Function(EventListRequest request)
    this.respond, {
    this.created = _noCreate,
    this.deleted = _noDelete,
    this.dateWritten = _noDateWrite,
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
  }) : respond = ((request) {
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
  }) : respond = null;

  static Never _noCreate(EventDraft draft, String clientRequestId) =>
      throw UnimplementedError('createEvent is not faked');

  static Never _noDelete(String id) =>
      throw UnimplementedError('deleteEvent is not faked');

  static Never _noDateWrite(EventDateRequest request) =>
      throw UnimplementedError('the date ${request.call} is not faked');

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

  final List<EventListRequest> requests = [];

  /// The id of each detail read, in order.
  final List<String> detailRequests = [];

  /// Each create, in order, recorded before it is answered.
  final List<EventCreateRequest> createRequests = [];

  /// The id of each delete, in order, recorded before it is answered.
  final List<String> deleteRequests = [];

  /// Each date write, in order, recorded before it is answered.
  final List<EventDateRequest> dateRequests = [];

  @override
  Future<PaginatedResult<EventSnapshot>> fetchEvents({
    int page = 1,
    int limit = EventRemoteDataSource.maxPageSize,
  }) async {
    final respond = this.respond;
    if (respond == null) {
      throw UnimplementedError('fetchEvents is not in a detail read');
    }
    final request = (page: page, limit: limit);
    requests.add(request);
    return respond(request);
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

  /// [answer], which a [call] other than a remove must have.
  static EventOccurrence _dated(String call, EventOccurrence? answer) =>
      answer ?? (throw StateError('the fake answered a date $call with none'));

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not faked');
}
