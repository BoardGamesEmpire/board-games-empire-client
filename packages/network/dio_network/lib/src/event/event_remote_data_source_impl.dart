import 'package:dio/dio.dart';
import 'package:dio_network/src/network/api_error_envelope.dart';
import 'package:dio_network/src/network/remote_failure.dart';
import 'package:dio_network/src/network/user_projection.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// [EventRemoteDataSource] over a **per-server** Dio instance (#496, #499,
/// #501).
///
/// The body is asked for as a `String` with the response type pinned on
/// every request, and `sendForJson` decodes it after the status is read and
/// classifies a failure through [_EventFailures]. It does not build or own
/// its Dio; the network installer constructs it from the per-server
/// container.
///
/// Failure taxonomy per the [EventRemoteDataSource] contract.
class EventRemoteDataSourceImpl implements EventRemoteDataSource {
  const EventRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  static const String _basePath = '/api/events';

  /// See `GameCollectionRemoteDataSourceImpl._plainBody`: `Response<String>`
  /// alone is not enough when the injected Dio's own response type is
  /// `bytes` or `stream`. A fresh instance per call, because `Options` is
  /// mutable.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  @override
  Future<PaginatedResult<EventSnapshot>> fetchEvents({
    int page = 1,
    int limit = EventRemoteDataSource.maxPageSize,
    bool includeArchived = false,
  }) => _fetchList(
    _basePath,
    page: page,
    limit: limit,
    action: 'Event list',
    route: _Route.list,
    includeArchived: includeArchived,
  );

  @override
  Future<PaginatedResult<EventSnapshot>> browseEvents({
    int page = 1,
    int limit = EventRemoteDataSource.maxPageSize,
  }) => _fetchList(
    '$_basePath/browse',
    page: page,
    limit: limit,
    action: 'Event browse',
    route: _Route.list,
  );

  @override
  Future<PaginatedResult<EventSnapshot>> fetchHouseholdEvents(
    String householdId, {
    int page = 1,
    int limit = EventRemoteDataSource.maxPageSize,
  }) {
    _checkId(householdId, name: 'householdId');
    return _fetchList(
      '/api/households/${Uri.encodeComponent(householdId)}/events',
      page: page,
      limit: limit,
      action: 'Household event list',
      route: _Route.householdList,
    );
  }

  /// One page of event rows from the list route at [path].
  Future<PaginatedResult<EventSnapshot>> _fetchList(
    String path, {
    required int page,
    required int limit,
    required String action,
    required _Route route,
    bool includeArchived = false,
  }) async {
    _checkPaging(page: page, limit: limit);

    final failures = _EventFailures(route);
    final response = await sendForJson(
      () => _dio.get<String>(
        path,
        options: _plainBody,
        queryParameters: {
          'page': page,
          'limit': limit,
          if (includeArchived) 'includeArchived': true,
        },
      ),
      action: action,
      // A list route is never absent for a caller who reached it: no events is
      // a 200 with an empty page. So a 404 here means the route is not
      // deployed, such as on a server older than the events routes. A
      // household's list is the exception: its path names the household, so
      // an enveloped 404 says the household is missing or deleted (#503).
      family: failures,
    );

    return parseRemote(
      failures,
      () => PaginatedResult.fromEnvelope(
        response.body,
        key: 'events',
        item: _mapListRow,
      ),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<EventSnapshot> fetchEvent(String id) async {
    _checkId(id);

    const action = 'Event fetch';
    const failures = _EventFailures(_Route.row);
    final response = await sendForJson(
      () => _dio.get<String>(_pathOf(id), options: _plainBody),
      action: action,
      // The path names one event, so an application 404 is the service saying
      // it is gone, or that the caller may not read it: the server answers
      // both alike.
      family: failures,
    );
    return parseRemote(
      failures,
      () => _mapDetail(_eventObject(response.body)),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<CreatedEvent> createEvent(
    EventDraft draft, {
    required String clientRequestId,
  }) async {
    _checkClientRequestId(clientRequestId);
    draft.checkSendable();

    const action = 'Event create';
    const failures = _EventFailures(_Route.create);
    final response = await sendForJson(
      () => _dio.post<String>(
        _basePath,
        options: _plainBody,
        data: _createBody(draft, clientRequestId),
      ),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
      () {
        final event = _eventObject(response.body);
        return (
          snapshot: _mapDetail(event),
          // A repeat of a create whose event was deleted since still answers
          // with it, and says when.
          deletedAt: _dateOrNull(event['deletedAt']),
        );
      },
      action: action,
      status: response.status,
    );
  }

  @override
  Future<void> deleteEvent(String id) async {
    _checkId(id);

    await sendForJson(
      () => _dio.delete<String>(_pathOf(id), options: _plainBody),
      action: 'Event delete',
      // The path names one event, and the delete is a write to it: an
      // application 404 is the event being gone, and an application 403 is
      // the API refusing this write.
      family: const _EventFailures(_Route.write),
      // The answer is `{ message, event }`, which the delete has no use for. A
      // 2xx is a delete that happened, so a body this client could not read
      // must not turn it into a failure.
      readBody: false,
    );
  }

  @override
  Future<Event> cancelEvent(String id, {String? reason}) async {
    _checkId(id);
    final trimmed = _checkedReason(reason);

    return _writeEvent(
      'Event cancel',
      '${_pathOf(id)}/cancel',
      data: {if (trimmed != null && trimmed.isNotEmpty) 'reason': trimmed},
    );
  }

  @override
  Future<Event> reopenEvent(String id) async {
    _checkId(id);
    return _writeEvent('Event reopen', '${_pathOf(id)}/reopen');
  }

  @override
  Future<Event> archiveEvent(String id) async {
    _checkId(id);
    return _writeEvent('Event archive', '${_pathOf(id)}/archive');
  }

  @override
  Future<Event> unarchiveEvent(String id) async {
    _checkId(id);
    return _writeEvent('Event unarchive', '${_pathOf(id)}/unarchive');
  }

  /// A status write to one event: a POST to [path] that answers
  /// `{ message, event }`, where the event carries its status and no dates.
  Future<Event> _writeEvent(
    String action,
    String path, {
    Map<String, dynamic>? data,
  }) async {
    const failures = _EventFailures(_Route.write);
    final response = await sendForJson(
      () => _dio.post<String>(path, options: _plainBody, data: data),
      action: action,
      // The path names one event, and the call is a write to it.
      family: failures,
    );
    return parseRemote(
      failures,
      () => _mapEvent(_eventObject(response.body)),
      action: action,
      status: response.status,
    );
  }

  /// [reason] trimmed, or null when none was given. A reason past the server's
  /// ceiling, in code points, throws before anything is sent.
  static String? _checkedReason(String? reason) {
    final trimmed = reason?.trim();
    if (trimmed != null &&
        trimmed.runes.length > EventRemoteDataSource.maxCancelReasonLength) {
      // The server's 400 for this is permanent, so it is not sent.
      throw ArgumentError.value(
        reason,
        'reason',
        'must be at most ${EventRemoteDataSource.maxCancelReasonLength} '
            'characters after trimming (the server rejects anything longer '
            'with a 400)',
      );
    }
    return trimmed;
  }

  @override
  Future<EventOccurrence> addOccurrence(
    String eventId,
    EventOccurrenceDraft draft, {
    required int sortOrder,
  }) async {
    _checkId(eventId, name: 'eventId');

    return _writeOccurrence(
      'Date add',
      _occurrencesPath(eventId),
      (path) => _dio.post<String>(
        path,
        options: _plainBody,
        data: {
          'label': ?draft.label,
          'startDate': ?draft.startDate?.toUtc().toIso8601String(),
          'endDate': ?draft.endDate?.toUtc().toIso8601String(),
          'location': ?draft.location,
          'sortOrder': sortOrder,
        },
      ),
    );
  }

  @override
  Future<EventOccurrence> updateOccurrence(
    String eventId,
    String occurrenceId,
    OccurrenceUpdate update,
  ) async {
    _checkOccurrenceIds(eventId, occurrenceId);
    if (update.isEmpty) {
      throw ArgumentError.value(update, 'update', 'must change something');
    }

    return _writeOccurrence(
      'Date update',
      _occurrencePath(eventId, occurrenceId),
      (path) => _dio.patch<String>(
        path,
        options: _plainBody,
        data: {
          // A cleared field goes as null, which the server writes as NULL.
          if (update.clearLabel) 'label': null else 'label': ?update.label,
          'startDate': ?update.startDate?.toUtc().toIso8601String(),
          if (update.clearEndDate)
            'endDate': null
          else
            'endDate': ?update.endDate?.toUtc().toIso8601String(),
          if (update.clearLocation)
            'location': null
          else
            'location': ?update.location,
        },
      ),
    );
  }

  @override
  Future<EventOccurrence> confirmOccurrence(
    String eventId,
    String occurrenceId,
  ) => _postStatus('Date confirm', 'confirm', eventId, occurrenceId);

  @override
  Future<EventOccurrence> declineOccurrence(
    String eventId,
    String occurrenceId,
  ) => _postStatus('Date decline', 'decline', eventId, occurrenceId);

  @override
  Future<EventOccurrence> cancelOccurrence(
    String eventId,
    String occurrenceId, {
    String? reason,
  }) async {
    _checkOccurrenceIds(eventId, occurrenceId);
    final trimmed = _checkedReason(reason);

    return _writeOccurrence(
      'Date cancel',
      '${_occurrencePath(eventId, occurrenceId)}/cancel',
      (path) => _dio.post<String>(
        path,
        options: _plainBody,
        data: {if (trimmed != null && trimmed.isNotEmpty) 'reason': trimmed},
      ),
    );
  }

  @override
  Future<void> removeOccurrence(String eventId, String occurrenceId) async {
    _checkOccurrenceIds(eventId, occurrenceId);

    await sendForJson(
      () => _dio.delete<String>(
        _occurrencePath(eventId, occurrenceId),
        options: _plainBody,
      ),
      action: 'Date remove',
      family: const _EventFailures(_Route.write),
      // As for the event delete: a 2xx is a removal that happened, whatever
      // the body says.
      readBody: false,
    );
  }

  @override
  Future<AvailabilityVote> submitAvailability(
    String eventId,
    String occurrenceId,
    AvailabilityResponse response,
  ) async {
    _checkOccurrenceIds(eventId, occurrenceId);
    if (response == AvailabilityResponse.unknown) {
      // It stands for a name this client could not read, and has none to send.
      throw ArgumentError.value(
        response,
        'response',
        'has no wire name, so it cannot be sent',
      );
    }

    const action = 'Availability vote';
    const failures = _EventFailures(_Route.write);
    final result = await sendForJson(
      () => _dio.post<String>(
        '${_occurrencePath(eventId, occurrenceId)}/availability',
        options: _plainBody,
        data: {'response': response.toWire()},
      ),
      action: action,
      // The path names one date of one event, and the call is a write to it.
      family: failures,
    );
    return parseRemote(
      failures,
      () => _mapVote(_voteObject(result.body)),
      action: action,
      status: result.status,
    );
  }

  @override
  Future<EventAttendee> updateAttendeeStatus(
    String eventId,
    String attendeeId,
    EventParticipationStatus status, {
    String? notes,
  }) async {
    _checkId(eventId, name: 'eventId');
    _checkId(attendeeId, name: 'attendeeId');
    if (status == EventParticipationStatus.unknown) {
      // It stands for a name this client could not read, and has none to send.
      throw ArgumentError.value(
        status,
        'status',
        'has no wire name, so it cannot be sent',
      );
    }

    const action = 'RSVP';
    const failures = _EventFailures(_Route.write);
    final result = await sendForJson(
      () => _dio.patch<String>(
        '${_pathOf(eventId)}/attendees/${Uri.encodeComponent(attendeeId)}'
        '/status',
        options: _plainBody,
        // A note left out is kept by the server, and an empty one clears it.
        data: {'status': status.toWire(), 'notes': ?notes},
      ),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
      () => _mapAttendee(_attendeeObject(result.body)),
      action: action,
      status: result.status,
    );
  }

  @override
  Future<EventAttendee> addAttendee(
    String eventId, {
    required String userId,
    required EventRole role,
  }) async {
    _checkId(eventId, name: 'eventId');
    _checkId(userId, name: 'userId');
    if (role == EventRole.host || role == EventRole.unknown) {
      // The host belongs to whoever created the event, and unknown has no
      // wire name.
      throw ArgumentError.value(role, 'role', 'cannot be given to an attendee');
    }

    const action = 'Add attendee';
    const failures = _EventFailures(_Route.attendeeAdd);
    final result = await sendForJson(
      () => _dio.post<String>(
        '${_pathOf(eventId)}/attendees',
        options: _plainBody,
        data: {'userId': userId, 'role': role.toWire()},
      ),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
      () => _mapAttendee(_attendeeObject(result.body)),
      action: action,
      status: result.status,
    );
  }

  @override
  Future<EventAttendee> removeAttendee(
    String eventId,
    String attendeeId,
  ) async {
    _checkId(eventId, name: 'eventId');
    _checkId(attendeeId, name: 'attendeeId');

    const action = 'Remove attendee';
    const failures = _EventFailures(_Route.write);
    final result = await sendForJson(
      () => _dio.delete<String>(
        '${_pathOf(eventId)}/attendees/${Uri.encodeComponent(attendeeId)}',
        options: _plainBody,
      ),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
      () => _mapAttendee(_attendeeObject(result.body)),
      action: action,
      status: result.status,
    );
  }

  /// How many attendees' games [fetchGamesPool] reads at once.
  static const int _poolReadsAtOnce = 4;

  @override
  Future<List<OfferedGame>> fetchGamesPool(
    String eventId, {
    required List<String> attendeeIds,
  }) async {
    _checkId(eventId, name: 'eventId');
    for (final attendeeId in attendeeIds) {
      _checkId(attendeeId, name: 'attendeeIds');
    }
    if (attendeeIds.isEmpty) return const [];

    // One slot per id, in the order given, so the answer keeps that order
    // whichever read lands first. A slot left null is an attendee who
    // answered 404.
    final slots = List<List<OfferedGame>?>.filled(attendeeIds.length, null);
    var next = 0;
    var failed = false;
    EventRemoteNotFoundException? notFound;

    // A small pool of workers, each taking the next id as it finishes one,
    // so a slow read holds up one worker rather than a batch. Once a read
    // fails no worker starts another; reads already in flight finish, and
    // what they answer is ignored.
    Future<void> worker() async {
      while (!failed && next < attendeeIds.length) {
        final index = next++;
        try {
          slots[index] = await _fetchOfferedGames(eventId, attendeeIds[index]);
        } on EventRemoteNotFoundException catch (error) {
          // The attendee left the event since the roster was read, or the
          // event is gone: the path names both, so a 404 says only that
          // one of them is. When every read says it, the throw below tells
          // the caller.
          notFound ??= error;
        } on Object {
          failed = true;
          rethrow;
        }
      }
    }

    final workers = attendeeIds.length < _poolReadsAtOnce
        ? attendeeIds.length
        : _poolReadsAtOnce;
    // Not eager: the pool settles once every read in flight has, and the
    // first failure is what it throws. Future.wait handles the rest, so a
    // second failure is never an unhandled error.
    await Future.wait([for (var i = 0; i < workers; i++) worker()]);

    if (slots.every((games) => games == null)) {
      // Every attendee answered 404: the event is gone, or all of them left.
      throw notFound!;
    }
    return [for (final games in slots) ...?games];
  }

  /// One attendee's offered games, `{ games: [...] }`.
  Future<List<OfferedGame>> _fetchOfferedGames(
    String eventId,
    String attendeeId,
  ) async {
    const action = 'Offered games';
    const failures = _EventFailures(_Route.row);
    final response = await sendForJson(
      () => _dio.get<String>(
        _offeredGamesPath(eventId, attendeeId),
        options: _plainBody,
      ),
      action: action,
      // The path names one attendee of one event, so an application 404 is
      // the service saying either is gone.
      family: failures,
    );
    return parseRemote(
      failures,
      () => _mapObjects(
        response.body['games'],
        field: 'games',
        item: _mapOfferedGame,
      ),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<OfferedGame> offerGame(
    String eventId,
    String attendeeId, {
    required String collectionId,
  }) async {
    _checkId(eventId, name: 'eventId');
    _checkId(attendeeId, name: 'attendeeId');
    _checkId(collectionId, name: 'collectionId');

    const action = 'Offer game';
    const failures = _EventFailures(_Route.gameOffer);
    final result = await sendForJson(
      () => _dio.post<String>(
        _offeredGamesPath(eventId, attendeeId),
        options: _plainBody,
        data: {'collectionId': collectionId},
      ),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
      () => _mapOfferedGame(_entryObject(result.body)),
      action: action,
      status: result.status,
    );
  }

  @override
  Future<void> takeBackGame(
    String eventId,
    String attendeeId,
    String offeredGameId,
  ) async {
    _checkId(eventId, name: 'eventId');
    _checkId(attendeeId, name: 'attendeeId');
    _checkId(offeredGameId, name: 'offeredGameId');

    await sendForJson(
      () => _dio.delete<String>(
        '${_offeredGamesPath(eventId, attendeeId)}/'
        '${Uri.encodeComponent(offeredGameId)}',
        options: _plainBody,
      ),
      action: 'Take back game',
      family: const _EventFailures(_Route.gameTakeBack),
      // The answer is `{ message, entry }`, which the take-back has no use
      // for: a 2xx is a take-back that happened.
      readBody: false,
    );
  }

  @override
  Future<List<EventNomination>> fetchNominations(String eventId) async {
    _checkId(eventId, name: 'eventId');

    const action = 'Nominations';
    const failures = _EventFailures(_Route.row);
    // By id, in the order first read: a nomination created mid-read shifts
    // the offsets of a newest-first list, so a later page can repeat a row
    // an earlier one held. The first is kept, and the list's keys stay
    // unique.
    final all = <String, EventNomination>{};
    for (var page = 1; ; page++) {
      final response = await sendForJson(
        () => _dio.get<String>(
          _nominationsPath(eventId),
          options: _plainBody,
          queryParameters: {
            'page': page,
            'limit': EventRemoteDataSource.maxPageSize,
          },
        ),
        action: action,
        // The path names one event, so an application 404 is the service
        // saying it is gone.
        family: failures,
      );
      final result = parseRemote(
        failures,
        () => PaginatedResult.fromEnvelope(
          response.body,
          key: 'nominations',
          item: _mapNomination,
        ),
        action: action,
        status: response.status,
      );
      final before = all.length;
      for (final nomination in result.items) {
        all.putIfAbsent(nomination.id, () => nomination);
      }
      if (!result.meta.hasMore) return all.values.toList();

      // More past the last page the server itself counted, or a page that
      // adds nothing new, is an envelope that contradicts itself, and
      // nothing else would stop the read until the server refused a page
      // past its offset ceiling.
      if (page >= result.meta.totalPages) {
        throw EventRemotePermanentException(
          '$action page $page reports another page past its own last page, '
          '${result.meta.totalPages}',
          statusCode: response.status,
        );
      }
      if (all.length == before) {
        throw EventRemotePermanentException(
          '$action page $page reports another page but adds no nomination '
          'not already read',
          statusCode: response.status,
        );
      }
    }
  }

  @override
  Future<EventNomination> fetchNomination(
    String eventId,
    String nominationId,
  ) async {
    _checkId(eventId, name: 'eventId');
    _checkId(nominationId, name: 'nominationId');

    const action = 'Nomination';
    const failures = _EventFailures(_Route.row);
    final response = await sendForJson(
      () => _dio.get<String>(
        _nominationPath(eventId, nominationId),
        options: _plainBody,
      ),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
      () => _mapNomination(_nominationObject(response.body)),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<EventNomination> nominate(
    String eventId, {
    required String platformGameId,
    required String suppliedFromId,
    String? occurrenceId,
  }) async {
    _checkId(eventId, name: 'eventId');
    _checkId(platformGameId, name: 'platformGameId');
    _checkId(suppliedFromId, name: 'suppliedFromId');
    if (occurrenceId != null) _checkId(occurrenceId, name: 'occurrenceId');

    const action = 'Nominate game';
    const failures = _EventFailures(_Route.nominate);
    final result = await sendForJson(
      () => _dio.post<String>(
        _nominationsPath(eventId),
        options: _plainBody,
        data: {
          'platformGameId': platformGameId,
          'suppliedFromId': suppliedFromId,
          'occurrenceId': ?occurrenceId,
        },
      ),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
      () => _mapNomination(_nominationObject(result.body)),
      action: action,
      status: result.status,
    );
  }

  @override
  Future<void> castVote(
    String eventId,
    String nominationId, {
    required VoteType voteType,
    String? comment,
  }) async {
    _checkId(eventId, name: 'eventId');
    _checkId(nominationId, name: 'nominationId');
    // Before anything is sent: an unknown vote has no wire name.
    if (voteType == VoteType.unknown) {
      throw ArgumentError.value(voteType, 'voteType', 'has no wire name');
    }

    await sendForJson(
      () => _dio.post<String>(
        '${_nominationPath(eventId, nominationId)}/votes',
        options: _plainBody,
        data: {'voteType': voteType.toWire(), 'comment': ?comment},
      ),
      action: 'Cast vote',
      family: const _EventFailures(_Route.write),
      // The answer is `{ message, vote }`, which nothing reads: the bloc
      // re-reads the nomination.
      readBody: false,
    );
  }

  @override
  Future<EventNomination> withdrawNomination(
    String eventId,
    String nominationId,
  ) async {
    _checkId(eventId, name: 'eventId');
    _checkId(nominationId, name: 'nominationId');

    const action = 'Withdraw nomination';
    const failures = _EventFailures(_Route.write);
    final result = await sendForJson(
      () => _dio.patch<String>(
        '${_nominationPath(eventId, nominationId)}/withdraw',
        options: _plainBody,
      ),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
      () => _mapNomination(_nominationObject(result.body)),
      action: action,
      status: result.status,
    );
  }

  @override
  Future<AvailabilitySummary> fetchAvailabilitySummary(String eventId) async {
    _checkId(eventId, name: 'eventId');

    const action = 'Availability summary';
    const failures = _EventFailures(_Route.row);
    final response = await sendForJson(
      () => _dio.get<String>(
        '${_occurrencesPath(eventId)}/summary/availability',
        options: _plainBody,
      ),
      action: action,
      // The path names one event, so an application 404 is the service saying
      // it is gone, as for the detail read.
      family: failures,
    );
    return parseRemote(
      failures,
      () => _mapSummary(_summaryObject(response.body)),
      action: action,
      status: response.status,
    );
  }

  Future<EventOccurrence> _postStatus(
    String action,
    String suffix,
    String eventId,
    String occurrenceId,
  ) async {
    _checkOccurrenceIds(eventId, occurrenceId);

    return _writeOccurrence(
      action,
      '${_occurrencePath(eventId, occurrenceId)}/$suffix',
      (path) => _dio.post<String>(path, options: _plainBody),
    );
  }

  /// Sends one date write to [path] and reads the date out of its answer,
  /// `{ message, occurrence }`.
  Future<EventOccurrence> _writeOccurrence(
    String action,
    String path,
    Future<Response<String>> Function(String path) request,
  ) async {
    const failures = _EventFailures(_Route.write);
    final response = await sendForJson(
      () => request(path),
      action: action,
      // The path names one date of one event, and the call is a write to it.
      family: failures,
    );
    return parseRemote(
      failures,
      () => _mapOccurrence(_occurrenceObject(response.body)),
      action: action,
      status: response.status,
    );
  }

  static String _pathOf(String id) => '$_basePath/${Uri.encodeComponent(id)}';

  static String _occurrencesPath(String eventId) =>
      '${_pathOf(eventId)}/occurrences';

  static String _occurrencePath(String eventId, String occurrenceId) =>
      '${_occurrencesPath(eventId)}/${Uri.encodeComponent(occurrenceId)}';

  static String _offeredGamesPath(String eventId, String attendeeId) =>
      '${_pathOf(eventId)}/attendees/${Uri.encodeComponent(attendeeId)}/games';

  static String _nominationsPath(String eventId) =>
      '${_pathOf(eventId)}/nominations';

  static String _nominationPath(String eventId, String nominationId) =>
      '${_nominationsPath(eventId)}/${Uri.encodeComponent(nominationId)}';

  // ── Mapping ─────────────────────────────────────────────────────────
  //
  // Field by field and not generated, so the mapping reads only what the
  // models hold. The rows carry more: the cancellation, deletion and
  // recurrence fields, and a guest's email address, none of which is read
  // (#496).

  /// Maps one row of the list: the event with the occurrences and policy the
  /// list embeds.
  ///
  /// No `attendees` key is read. The list serves no roster, so the snapshot
  /// says it was not asked, whatever a row carries. The caller's own
  /// `attendance` is read (#667).
  static EventSnapshot _mapListRow(Map<String, dynamic> json) => EventSnapshot(
    event: _mapEvent(json),
    occurrences: _mapOccurrences(json['occurrences']),
    policy: _mapPolicy(json['policy']),
    attendance: _mapAttendance(json['attendance']),
  );

  /// Maps the detail's event: the parts of a list row, and the roster.
  ///
  /// The roster must be a list. An empty one is a caller who may not read the
  /// roster, and a missing or mistyped one is a contract breach: reading it as
  /// "nobody" would pass a payload this client failed to read off as an event
  /// with no one on it.
  static EventSnapshot _mapDetail(Map<String, dynamic> json) => EventSnapshot(
    event: _mapEvent(json),
    occurrences: _mapOccurrences(json['occurrences']),
    policy: _mapPolicy(json['policy']),
    attendees: _mapObjects(
      json['attendees'],
      field: 'attendees',
      item: _mapAttendee,
    ),
    attendance: _mapAttendance(json['attendance']),
  );

  /// Reads the event out of a detail body, `{ "event": { ... } }`.
  static Map<String, dynamic> _eventObject(Map<String, dynamic> body) {
    final event = body['event'];
    if (event is! Map<String, dynamic>) {
      throw const FormatException('response is missing an "event" object');
    }
    return event;
  }

  /// Reads the date out of a date write's body, `{ "occurrence": { ... } }`.
  static Map<String, dynamic> _occurrenceObject(Map<String, dynamic> body) {
    final occurrence = body['occurrence'];
    if (occurrence is! Map<String, dynamic>) {
      throw const FormatException('response is missing an "occurrence" object');
    }
    return occurrence;
  }

  /// Reads the attendee out of an RSVP's body, `{ "attendee": { ... } }`.
  static Map<String, dynamic> _attendeeObject(Map<String, dynamic> body) {
    final attendee = body['attendee'];
    if (attendee is! Map<String, dynamic>) {
      throw const FormatException('response is missing an "attendee" object');
    }
    return attendee;
  }

  /// Reads the vote out of a vote's body, `{ "vote": { ... } }`.
  static Map<String, dynamic> _voteObject(Map<String, dynamic> body) {
    final vote = body['vote'];
    if (vote is! Map<String, dynamic>) {
      throw const FormatException('response is missing a "vote" object');
    }
    return vote;
  }

  /// Reads the summary out of its body, `{ "summary": { ... } }`.
  static Map<String, dynamic> _summaryObject(Map<String, dynamic> body) {
    final summary = body['summary'];
    if (summary is! Map<String, dynamic>) {
      throw const FormatException('response is missing a "summary" object');
    }
    return summary;
  }

  /// Reads the offered game out of an offer's body, `{ "entry": { ... } }`.
  static Map<String, dynamic> _entryObject(Map<String, dynamic> body) =>
      _nestedObject(body['entry'], 'entry');

  /// Reads the nomination out of a body, `{ "nomination": { ... } }`.
  static Map<String, dynamic> _nominationObject(Map<String, dynamic> body) =>
      _nestedObject(body['nomination'], 'nomination');

  /// One nomination as the server serves it (#517).
  ///
  /// The game's title, thumbnail and platform come from the nested
  /// `platformGame`; the supplying pool row's id is the `suppliedFromId`
  /// column. A nominator who is a guest has no `user`, so no username. An
  /// empty thumbnail is none. The `priority` the votes carry is not read. A
  /// vote with no `eligible` fails its cast, a [TypeError] that [parseRemote]
  /// turns into a contract break, as it does any field this can't read: the
  /// server marks every vote, so a missing mark is not a vote that counts.
  static EventNomination _mapNomination(Map<String, dynamic> json) {
    final platformGame = _nestedObject(json['platformGame'], 'platformGame');
    final game = _nestedObject(platformGame['game'], 'platformGame.game');
    final platform = _nestedObject(
      platformGame['platform'],
      'platformGame.platform',
    );
    final nominatedBy = json['nominatedBy'];
    final user = nominatedBy is Map<String, dynamic>
        ? nominatedBy['user']
        : null;
    final username = user is Map<String, dynamic>
        ? user['username'] as String?
        : null;
    final thumbnail = game['thumbnail'] as String?;
    final pausedFrom = json['pausedFrom'] as String?;
    return EventNomination(
      id: json['id'] as String,
      eventId: json['eventId'] as String,
      occurrenceId: json['occurrenceId'] as String?,
      platformGameId: json['platformGameId'] as String,
      gameId: game['id'] as String,
      title: game['title'] as String,
      platformName: platform['name'] as String,
      thumbnail: thumbnail == null || thumbnail.isEmpty ? null : thumbnail,
      status: NominationStatus.fromWire(json['status'] as String),
      pausedFrom: pausedFrom == null
          ? null
          : NominationStatus.fromWire(pausedFrom),
      votingDeadline: _dateOrNull(json['votingDeadline']),
      nominatedById: json['nominatedById'] as String,
      nominatedByUsername: username,
      suppliedFromId: json['suppliedFromId'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      votes: _mapObjects(
        json['votes'],
        field: 'votes',
        item: _mapNominationVote,
      ),
    );
  }

  static EventNominationVote _mapNominationVote(Map<String, dynamic> json) =>
      EventNominationVote(
        id: json['id'] as String,
        attendeeId: json['attendeeId'] as String,
        voteType: VoteType.fromWire(json['voteType'] as String),
        eligible: json['eligible'] as bool,
        comment: json['comment'] as String?,
      );

  /// [raw] as an object, or a [FormatException] naming [field].
  static Map<String, dynamic> _nestedObject(Object? raw, String field) {
    if (raw is! Map<String, dynamic>) {
      throw FormatException(
        '"$field" is ${raw.runtimeType}, expected an object',
      );
    }
    return raw;
  }

  static Event _mapEvent(Map<String, dynamic> json) => Event(
    id: json['id'] as String,
    title: json['title'] as String,
    createdById: json['createdById'] as String,
    householdId: json['householdId'] as String?,
    description: json['description'] as String?,
    image: json['image'] as String?,
    location: json['location'] as String?,
    url: json['url'] as String?,
    type: EventType.fromWire(json['type'] as String),
    reach: Reach.fromWire(json['reach'] as String),
    status: EventStatus.fromWire(json['status'] as String),
    schedulingMode: EventSchedulingMode.fromWire(
      json['schedulingMode'] as String,
    ),
    cancelReason: json['cancelReason'] as String?,
    cancelledAt: _dateOrNull(json['cancelledAt']),
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );

  static List<EventOccurrence> _mapOccurrences(Object? raw) =>
      _mapObjects(raw, field: 'occurrences', item: _mapOccurrence);

  static EventOccurrence _mapOccurrence(Map<String, dynamic> json) =>
      EventOccurrence(
        id: json['id'] as String,
        eventId: json['eventId'] as String,
        label: json['label'] as String?,
        startDate: _dateOrNull(json['startDate']),
        endDate: _dateOrNull(json['endDate']),
        location: json['location'] as String?,
        status: OccurrenceStatus.fromWire(json['status'] as String),
        sortOrder: json['sortOrder'] as int,
        confirmedAt: _dateOrNull(json['confirmedAt']),
        declinedAt: _dateOrNull(json['declinedAt']),
        cancelledAt: _dateOrNull(json['cancelledAt']),
        cancelReason: json['cancelReason'] as String?,
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );

  /// Maps the embedded policy. Null is an event with none, or a detail read by
  /// a caller who may not read it (backend#560); either way the model carries
  /// no policy.
  static EventPolicy? _mapPolicy(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map<String, dynamic>) {
      throw FormatException(
        'event "policy" is ${raw.runtimeType}, expected an object or null',
      );
    }
    return EventPolicy(
      id: raw['id'] as String,
      eventId: raw['eventId'] as String,
      allowMemberInvites: raw['allowMemberInvites'] as bool,
      allowGuestInvites: raw['allowGuestInvites'] as bool,
      maxAttendees: raw['maxAttendees'] as int?,
      restrictToGameCategories: raw['restrictToGameCategories'] as bool,
      requireHostApprovalToJoin: raw['requireHostApprovalToJoin'] as bool,
      allowSpectators: raw['allowSpectators'] as bool,
      maxTotalParticipants: raw['maxTotalParticipants'] as int?,
      strictCapacity: raw['strictCapacity'] as bool,
      gameAdditionMode: GameAdditionMode.fromWire(
        raw['gameAdditionMode'] as String,
      ),
      restrictToAttendeePool: raw['restrictToAttendeePool'] as bool,
      fillerMaxPlayTime: raw['fillerMaxPlayTime'] as int?,
      voteThresholdType: VoteThresholdType.fromWire(
        raw['voteThresholdType'] as String,
      ),
      voteThresholdValue: raw['voteThresholdValue'] as int?,
      voteQuorumType: VoteQuorumType.fromWire(raw['voteQuorumType'] as String),
      voteQuorumValue: raw['voteQuorumValue'] as int?,
      voteEligibility: VoteEligibility.fromWire(
        raw['voteEligibility'] as String,
      ),
      interestedWeight: InterestedWeight.fromWire(
        raw['interestedWeight'] as String,
      ),
      votingWindowHours: raw['votingWindowHours'] as int?,
      createdAt: DateTime.parse(raw['createdAt'] as String),
      updatedAt: DateTime.parse(raw['updatedAt'] as String),
    );
  }

  static EventAttendee _mapAttendee(Map<String, dynamic> json) {
    final user = readUserProjection(json['user'], row: 'attendee');
    return EventAttendee(
      id: json['id'] as String,
      eventId: json['eventId'] as String,
      userId: json['userId'] as String?,
      guestName: json['guestName'] as String?,
      username: user.username,
      displayName: user.displayName,
      avatarUrl: user.avatarUrl,
      notes: json['notes'] as String?,
      status: EventParticipationStatus.fromWire(json['status'] as String),
      role: _mapRole(json['role']),
      rsvpDate: _dateOrNull(json['rsvpDate']),
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  /// Reads the caller's own answer off a list or detail row, `{ attendeeId,
  /// status, role, rsvpDate }`.
  ///
  /// Null, or a missing key, is a caller with no attendee row, and so is every
  /// browse row. `role` here is the role's name, a string, not the roster's
  /// nested projection that [_mapRole] reads. A shape that is wrong is a
  /// contract breach and throws, rather than passing for "no answer".
  static EventAttendance? _mapAttendance(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map<String, dynamic>) {
      throw FormatException(
        'event "attendance" is ${raw.runtimeType}, expected an object or null',
      );
    }
    final role = raw['role'];
    if (role != null && role is! String) {
      throw FormatException(
        'attendance "role" is ${role.runtimeType}, '
        'expected a role name or null',
      );
    }
    return EventAttendance(
      attendeeId: raw['attendeeId'] as String,
      status: EventParticipationStatus.fromWire(raw['status'] as String),
      role: role == null ? null : EventRole.fromWire(role as String),
      rsvpDate: _dateOrNull(raw['rsvpDate']),
    );
  }

  /// Reads the role name out of the embedded join projection,
  /// `{ ..., role: { id, name } }`.
  ///
  /// A null projection is an attendee with no role binding, which the model
  /// represents as a null role. A projection whose shape is wrong is a contract
  /// breach and throws: it must not be laundered into [EventRole.unknown],
  /// which would make a parsing failure indistinguishable from a custom server
  /// role.
  static EventRole? _mapRole(Object? projection) {
    if (projection == null) return null;
    if (projection is! Map<String, dynamic>) {
      throw FormatException(
        'attendee "role" is ${projection.runtimeType}, expected the embedded '
        'role projection',
      );
    }
    final role = projection['role'];
    if (role is! Map<String, dynamic>) {
      throw FormatException(
        'attendee "role" projection is missing its nested "role" object, got '
        '${role.runtimeType}',
      );
    }
    final name = role['name'];
    if (name is! String) {
      throw FormatException(
        'attendee role is missing a "name", got ${name.runtimeType}',
      );
    }
    return EventRole.fromWire(name);
  }

  static AvailabilityVote _mapVote(Map<String, dynamic> json) =>
      AvailabilityVote(
        id: json['id'] as String,
        occurrenceId: json['occurrenceId'] as String,
        attendeeId: json['attendeeId'] as String,
        response: AvailabilityResponse.fromWire(json['response'] as String),
        createdAt: DateTime.parse(json['createdAt'] as String),
        updatedAt: DateTime.parse(json['updatedAt'] as String),
      );

  /// Maps the summary's dates. Its `attendees` and `eligibleVoters` are not
  /// read (backend#759), and neither is anything a date carries beyond its
  /// tallies and voters.
  static AvailabilitySummary _mapSummary(Map<String, dynamic> json) =>
      AvailabilitySummary(
        occurrences: _mapObjects(
          json['occurrences'],
          field: 'occurrences',
          item: _mapOccurrenceAvailability,
        ),
        rosterVisible: switch (json['attendees']) {
          {'total': final int total} => total > 0,
          _ => true,
        },
      );

  static OccurrenceAvailability _mapOccurrenceAvailability(
    Map<String, dynamic> json,
  ) => OccurrenceAvailability(
    occurrenceId: json['occurrenceId'] as String,
    available: json['available'] as int,
    maybe: json['maybe'] as int,
    unavailable: json['unavailable'] as int,
    voters: _mapObjects(json['voters'], field: 'voters', item: _mapVoter),
  );

  static AvailabilityVoter _mapVoter(Map<String, dynamic> json) =>
      AvailabilityVoter(
        attendeeId: json['attendeeId'] as String,
        response: AvailabilityResponse.fromWire(json['response'] as String),
        eligible: json['eligible'] as bool,
      );

  /// An offered game's medium, or null when [raw] is not a medium this client
  /// knows: absent, null, not a string, or a name a newer server added
  /// (#516).
  ///
  /// Lenient where the user's own collection rows are strict: the pool is
  /// other people's rows, and one unknown medium must not fail every event's
  /// pool read. Only `fromWire`'s own refusal of a name is caught.
  static GameMedium? _offeredMediumOrNull(Object? raw) {
    if (raw is! String) return null;
    try {
      return GameMedium.fromWire(raw);
    } on FormatException {
      return null;
    }
  }

  /// Maps one offered game (#516): the list row's ids, and from the owner's
  /// collection row its medium and the game and platform under it.
  ///
  /// The collection row comes whole, the owner's rating, comment and play
  /// counts with it, and only the keys read here are read: the rest is the
  /// owner's, and has no field to land in (backend#1185). The players and
  /// play time are null when missing, as in an offer's answer. A thumbnail
  /// that is an empty string is none, and so is a medium this client does
  /// not know (see [_offeredMediumOrNull]).
  static OfferedGame _mapOfferedGame(Map<String, dynamic> json) {
    final collection = _nestedObject(json['collection'], 'collection');
    final platformGame = _nestedObject(
      collection['platformGame'],
      'collection.platformGame',
    );
    final game = _nestedObject(
      platformGame['game'],
      'collection.platformGame.game',
    );
    final platform = _nestedObject(
      platformGame['platform'],
      'collection.platformGame.platform',
    );
    final thumbnail = game['thumbnail'] as String?;
    return OfferedGame(
      id: json['id'] as String,
      attendeeId: json['attendeeId'] as String,
      collectionId: json['collectionId'] as String,
      platformGameId: platformGame['id'] as String,
      gameId: game['id'] as String,
      title: game['title'] as String,
      platformName: platform['name'] as String,
      thumbnail: thumbnail == null || thumbnail.isEmpty ? null : thumbnail,
      medium: _offeredMediumOrNull(collection['medium']),
      minPlayers: game['minPlayers'] as int?,
      maxPlayers: game['maxPlayers'] as int?,
      minPlayTime: game['minPlayTime'] as int?,
      maxPlayTime: game['maxPlayTime'] as int?,
    );
  }

  /// Maps each object in the list [raw]. A list that is missing or of the
  /// wrong type throws, because reading it as empty would pass a payload this
  /// client failed to read off as an event with none of them. [field] names it
  /// in the error.
  static List<T> _mapObjects<T>(
    Object? raw, {
    required String field,
    required T Function(Map<String, dynamic> json) item,
  }) {
    if (raw is! List) {
      throw FormatException(
        raw == null
            ? 'event is missing its "$field" list'
            : 'event "$field" is ${raw.runtimeType}, expected a list',
      );
    }
    return raw
        .map((entry) {
          if (entry is! Map<String, dynamic>) {
            throw FormatException(
              'an entry in "$field" is ${entry.runtimeType}, expected an '
              'object',
            );
          }
          return item(entry);
        })
        .toList(growable: false);
  }

  static DateTime? _dateOrNull(Object? value) =>
      value == null ? null : DateTime.parse(value as String);

  // ── Request body ────────────────────────────────────────────────────

  /// The create's body. A field the draft leaves null is left out, and so is an
  /// empty list, so the server's defaults apply.
  ///
  /// Runs after [EventDraft.checkSendable], which is what keeps `toWire` from
  /// throwing on an `unknown` value.
  static Map<String, Object?> _createBody(
    EventDraft draft,
    String clientRequestId,
  ) => {
    'title': draft.title,
    // Sent as given: the server trims it before it stores or matches it.
    'clientRequestId': clientRequestId,
    'schedulingMode': draft.schedulingMode.toWire(),
    'householdId': ?draft.householdId,
    'description': ?draft.description,
    'location': ?draft.location,
    'url': ?draft.url,
    'type': ?draft.type?.toWire(),
    'reach': ?draft.reach?.toWire(),
    if (draft.occurrences.isNotEmpty)
      'occurrences': [
        for (final (index, occurrence) in draft.occurrences.indexed)
          {
            'label': ?occurrence.label,
            'startDate': ?occurrence.startDate?.toUtc().toIso8601String(),
            'endDate': ?occurrence.endDate?.toUtc().toIso8601String(),
            'location': ?occurrence.location,
            'sortOrder': index,
          },
      ],
    if (draft.policy case final policy?)
      'policy': {
        'gameAdditionMode': ?policy.gameAdditionMode?.toWire(),
        'voteThresholdType': ?policy.voteThresholdType?.toWire(),
        'voteThresholdValue': ?policy.voteThresholdValue,
        'voteQuorumType': ?policy.voteQuorumType?.toWire(),
        'voteQuorumValue': ?policy.voteQuorumValue,
        'votingWindowHours': ?policy.votingWindowHours,
      },
    if (draft.inviteUserIds.isNotEmpty) 'inviteUserIds': draft.inviteUserIds,
  };

  // ── Guards: requests the server is guaranteed to reject ─────────────

  void _checkPaging({required int page, required int limit}) {
    const maxPageSize = EventRemoteDataSource.maxPageSize;
    if (limit < 1 || limit > maxPageSize) {
      throw ArgumentError.value(
        limit,
        'limit',
        'must be between 1 and $maxPageSize (the server rejects a larger '
            'page rather than clamping it)',
      );
    }
    if (page < 1) {
      throw ArgumentError.value(page, 'page', 'is 1-based');
    }
  }

  /// The server trims `clientRequestId`, then requires 1 to
  /// [EventRemoteDataSource.maxClientRequestIdLength] characters, and answers a
  /// violation with a 400. That is permanent, and a permanent create is parked
  /// on its first attempt, so a key the caller got wrong is refused here with
  /// an error outside the transient and permanent split (#499), as the
  /// household create does.
  ///
  /// This matches the server exactly for ASCII keys, which every key this
  /// client mints is. Past ASCII the two can disagree at the edges: Dart's
  /// `trim` also strips U+0085, which the server's does not, and the server
  /// counts a surrogate pair as one character where `length` counts two.
  void _checkClientRequestId(String clientRequestId) {
    const maxLength = EventRemoteDataSource.maxClientRequestIdLength;
    final length = clientRequestId.trim().length;
    if (length == 0 || length > maxLength) {
      throw ArgumentError.value(
        clientRequestId,
        'clientRequestId',
        'must be 1 to $maxLength characters after trimming (the server '
            'rejects anything else with a 400)',
      );
    }
  }

  /// An empty id would send `GET /api/events/`, which the server routes to
  /// the list, so its 200 would fail to parse and read as the server breaking
  /// the contract rather than the caller's mistake. A `DELETE /api/events/`
  /// has no route, and its 404 would read as the event being gone.
  void _checkId(String id, {String name = 'id'}) {
    if (id.isEmpty) {
      throw ArgumentError.value(id, name, 'must not be empty');
    }
  }

  /// An empty occurrence id would send the request to the event's dates
  /// route, and read the answer as if it were about one date.
  void _checkOccurrenceIds(String eventId, String occurrenceId) {
    _checkId(eventId, name: 'eventId');
    _checkId(occurrenceId, name: 'occurrenceId');
  }
}

/// How the event source builds its failures for the shared classifier.
///
/// The [route] says what the request's path names, which decides what an
/// application 403 or 404 means.
final class _EventFailures extends RemoteFailureFamily<EventRemoteException> {
  const _EventFailures(this.route)
    : super(
        transient: EventRemoteTransientException.new,
        permanent: EventRemotePermanentException.new,
      );

  final _Route route;

  /// The enveloped 403, 404 and 400 the event routes answer, by [route].
  ///
  /// On a write the API is refusing this request, not saying the caller may
  /// not read events. Nest answers an unregistered route with the same
  /// envelope as an application 404, so on the list route even an enveloped
  /// 404 means "not deployed", not "no rows", and falls to the shared
  /// default. On a row route, and on a write to one, a 404 is the service
  /// saying the row is gone. On the create it is the service refusing an
  /// unknown household or invitee.
  ///
  /// That last one is read as a refusal although a server without the route
  /// answers alike. Parked, a create that was never routable is bounded and
  /// can be discarded by hand. Transient, it would retry forever. The
  /// envelope's message can name an invitee the server has no account for
  /// (#499).
  ///
  /// A write's enveloped 400 with one message is the server judging the write
  /// against the row as it stands now. The validation pipe's 400 lists one
  /// per value it refused, and falls to permanent: the same request is
  /// refused again. The event delete shares this route, and the server never
  /// answers it 400. The event status writes share it too, and their 400 is a
  /// conflict with the event's status as it stands. An offer's is too, for a
  /// collection entry removed since (#516), and a nomination's for a pool row
  /// that does not match its game (#517). The vote and the withdrawal share
  /// [_Route.write], and their 400 is the nomination's status as it stands.
  @override
  EventRemoteException? refused(RemoteRefusal refusal) {
    if (!refusal.fromApi) return null;
    final status = refusal.status;
    final body = refusal.body;
    final message = refusal.message;
    final cause = refusal.cause;
    if (status == 403) {
      return switch (route) {
        _Route.create => EventCreateRefusedException(
          message,
          cause: cause,
          statusCode: status,
          apiMessage: apiErrorField(body, 'message'),
        ),
        _Route.write ||
        _Route.attendeeAdd ||
        _Route.gameOffer ||
        _Route.gameTakeBack ||
        _Route.nominate => EventWriteRefusedException(
          message,
          cause: cause,
          statusCode: status,
          apiMessage: apiErrorField(body, 'message'),
        ),
        _Route.list ||
        _Route.householdList ||
        _Route.row => EventRemoteForbiddenException(
          message,
          cause: cause,
          statusCode: status,
        ),
      };
    }
    if (status == 404) {
      return switch (route) {
        _Route.row ||
        _Route.householdList ||
        _Route.write ||
        _Route.attendeeAdd ||
        _Route.gameOffer ||
        _Route.gameTakeBack ||
        _Route.nominate => EventRemoteNotFoundException(
          message,
          cause: cause,
          statusCode: status,
        ),
        _Route.create => EventCreateRefusedException(
          message,
          cause: cause,
          statusCode: status,
          apiMessage: apiErrorField(body, 'message'),
        ),
        _Route.list => null,
      };
    }
    if (status == 409 &&
        (route == _Route.attendeeAdd ||
            route == _Route.gameOffer ||
            route == _Route.gameTakeBack ||
            route == _Route.nominate)) {
      // The user is already on the event, the game is already offered, the
      // game still supplies a nomination or a lineup, or a nomination's
      // supplier is not attending. A 409 asking for a
      // retry never gets here: the shared classifier reads it as transient
      // first.
      return EventWriteConflictException(
        message,
        cause: cause,
        statusCode: status,
        apiMessage: apiErrorField(body, 'message'),
      );
    }
    if (status == 400 &&
        (route == _Route.write ||
            route == _Route.gameOffer ||
            route == _Route.nominate) &&
        apiErrorField(body, 'message') != null) {
      return EventWriteConflictException(
        message,
        cause: cause,
        statusCode: status,
        apiMessage: apiErrorField(body, 'message'),
      );
    }
    return null;
  }
}

/// What a request's path names, which decides what an application 403 or 404
/// from it means.
enum _Route {
  /// `GET /api/events`, a route that is never absent for a caller who reached
  /// it.
  list,

  /// `GET /api/households/:householdId/events`, whose path names a household:
  /// an enveloped 404 says it is missing or deleted (#503).
  householdList,

  /// `GET /api/events/:id` and the poll's summary under it, which name one
  /// event, and `GET /api/events/:id/attendees/:aid/games`, which names one
  /// attendee of it (#516), and `GET /api/events/:id/nominations` with the
  /// single nomination under it (#517).
  row,

  /// `POST /api/events`, whose 403 and 404 refuse that create.
  create,

  /// A write to one event or to one of its dates: `DELETE /api/events/:id`,
  /// the event status writes (`cancel`, `reopen`, `archive`, `unarchive`) and
  /// the date routes under it, a vote included. Its 403 refuses that write, its
  /// 404 says the event or date is gone, and its enveloped 400 with one message
  /// is a conflict with the row as it stands (#506), for a status write the
  /// event's status. The event delete is never answered 400.
  write,

  /// `POST /api/events/:id/attendees` (#510). It maps as [write] does, and
  /// its 404 is the event or the invitee (the service refuses an unknown
  /// user), its 403 a missing right or the invitee's block or preference, and
  /// its enveloped 409 a user already on the event.
  attendeeAdd,

  /// `POST /api/events/:id/attendees/:aid/games` (#516). Its 403 refuses the
  /// offer (the collection entry is someone else's, or the caller may not
  /// offer for this attendee), its 404 is the event, the attendee or the
  /// collection entry missing, its enveloped 409 a game already offered, and
  /// its enveloped 400 with one message an entry removed from the collection
  /// since.
  gameOffer,

  /// `DELETE /api/events/:id/attendees/:aid/games/:gid` (#516). Its 403
  /// refuses the take-back, its 404 is no such offered game (or one already
  /// taken back), and its enveloped 409 a game that still supplies a
  /// nomination or a lineup. The server never answers it 400.
  gameTakeBack,

  /// `POST /api/events/:id/nominations` (#517). Its 403 refuses the
  /// nomination (the mode allows only the host, or the role holds no grant),
  /// its 404 is the event, the date or the pool row gone, its enveloped 409 a
  /// supplier who is not attending, and its enveloped 400 with one message a
  /// pool row that does not match the game.
  nominate,
}
