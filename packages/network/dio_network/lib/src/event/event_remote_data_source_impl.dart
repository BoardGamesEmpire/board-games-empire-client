import 'package:dio/dio.dart';
import 'package:dio_network/src/event/event_json.dart';
import 'package:dio_network/src/network/api_error_envelope.dart';
import 'package:dio_network/src/network/json_reads.dart';
import 'package:dio_network/src/network/remote_failure.dart';
import 'package:dio_network/src/network/request_guards.dart';
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
  }) async {
    checkPathId(householdId, name: 'householdId');
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
    checkPage(
      page: page,
      limit: limit,
      maxSize: EventRemoteDataSource.maxPageSize,
      maxDepth: serverMaxPageDepth,
    );

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
        item: mapListRow,
      ),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<EventSnapshot> fetchEvent(String id) async {
    checkPathId(id);

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
      () => mapDetail(
        requireObject(response.body['event'], 'event'),
        servesDateRules: true,
      ),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<CreatedEvent> createEvent(
    EventDraft draft, {
    required String clientRequestId,
  }) async {
    checkClientRequestId(
      clientRequestId,
      maxLength: EventRemoteDataSource.maxClientRequestIdLength,
    );
    draft.checkSendable();

    const action = 'Event create';
    const failures = _EventFailures(_Route.create);
    final response = await sendForJson(
      () => _dio.post<String>(
        _basePath,
        options: _plainBody,
        data: eventCreateBody(draft, clientRequestId),
      ),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
      () {
        final event = requireObject(response.body['event'], 'event');
        return (
          snapshot: mapDetail(event, servesDateRules: false),
          // A repeat of a create whose event was deleted since still answers
          // with it, and says when.
          deletedAt: dateOrNull(event['deletedAt']),
        );
      },
      action: action,
      status: response.status,
    );
  }

  @override
  Future<void> deleteEvent(String id) async {
    checkPathId(id);

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
    checkPathId(id);
    final trimmed = _checkedReason(reason);

    return _writeEvent(
      'Event cancel',
      '${_pathOf(id)}/cancel',
      data: {if (trimmed != null && trimmed.isNotEmpty) 'reason': trimmed},
    );
  }

  @override
  Future<Event> reopenEvent(String id) async {
    checkPathId(id);
    return _writeEvent('Event reopen', '${_pathOf(id)}/reopen');
  }

  @override
  Future<Event> archiveEvent(String id) async {
    checkPathId(id);
    return _writeEvent('Event archive', '${_pathOf(id)}/archive');
  }

  @override
  Future<Event> unarchiveEvent(String id) async {
    checkPathId(id);
    return _writeEvent('Event unarchive', '${_pathOf(id)}/unarchive');
  }

  @override
  Future<Event> updateEvent(String id, EventUpdate update) async {
    checkPathId(id);
    _checkNotEmpty(update.isEmpty, update);

    return _writeEvent(
      'Event update',
      _pathOf(id),
      patch: true,
      data: {
        'title': ?update.title,
        // A cleared field goes as null, which the server writes as NULL.
        if (update.clearDescription)
          'description': null
        else
          'description': ?update.description,
        if (update.clearLocation)
          'location': null
        else
          'location': ?update.location,
        if (update.clearUrl) 'url': null else 'url': ?update.url,
        'type': ?update.type?.toWire(),
        'reach': ?update.reach?.toWire(),
      },
    );
  }

  @override
  Future<EventPolicy?> updateEventPolicy(
    String id,
    EventPolicyUpdate update,
  ) async {
    checkPathId(id);
    _checkNotEmpty(update.isEmpty, update);

    const action = 'Event policy update';
    const failures = _EventFailures(_Route.write);
    final response = await sendForJson(
      () => _dio.patch<String>(
        '${_pathOf(id)}/policy',
        options: _plainBody,
        data: {
          'gameAdditionMode': ?update.gameAdditionMode?.toWire(),
          'voteThresholdType': ?update.voteThresholdType?.toWire(),
          'voteThresholdValue': ?update.voteThresholdValue,
          'voteQuorumType': ?update.voteQuorumType?.toWire(),
          'voteQuorumValue': ?update.voteQuorumValue,
          if (update.clearVotingWindowHours)
            'votingWindowHours': null
          else
            'votingWindowHours': ?update.votingWindowHours,
        },
      ),
      action: action,
      family: failures,
    );
    // Null for a caller who may change the rules but not read them: the
    // rules are saved all the same.
    return parseRemote(
      failures,
      () => mapPolicy(response.body['policy'], served: true),
      action: action,
      status: response.status,
    );
  }

  static void _checkNotEmpty(bool isEmpty, Object update) {
    if (isEmpty) {
      throw ArgumentError.value(update, 'update', 'must change something');
    }
  }

  /// A write to one event: a POST, or a PATCH when [patch], to [path] that
  /// answers `{ message, event }`, where the event carries its status. Only
  /// the event's own fields are read: a status write's answer has no dates,
  /// and the PATCH's has every date and the policy, which are left unread.
  Future<Event> _writeEvent(
    String action,
    String path, {
    Map<String, dynamic>? data,
    bool patch = false,
  }) async {
    const failures = _EventFailures(_Route.write);
    final response = await sendForJson(
      () => patch
          ? _dio.patch<String>(path, options: _plainBody, data: data)
          : _dio.post<String>(path, options: _plainBody, data: data),
      action: action,
      // The path names one event, and the call is a write to it.
      family: failures,
    );
    return parseRemote(
      failures,
      () => mapEvent(requireObject(response.body['event'], 'event')),
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
    checkPathId(eventId, name: 'eventId');

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
    checkPathId(eventId, name: 'eventId');
    checkPathId(occurrenceId, name: 'occurrenceId');
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
    checkPathId(eventId, name: 'eventId');
    checkPathId(occurrenceId, name: 'occurrenceId');
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
    checkPathId(eventId, name: 'eventId');
    checkPathId(occurrenceId, name: 'occurrenceId');

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
    checkPathId(eventId, name: 'eventId');
    checkPathId(occurrenceId, name: 'occurrenceId');
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
      () => mapVote(requireObject(result.body['vote'], 'vote')),
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
    checkPathId(eventId, name: 'eventId');
    checkPathId(attendeeId, name: 'attendeeId');
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
      () => mapAttendee(requireObject(result.body['attendee'], 'attendee')),
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
    checkPathId(eventId, name: 'eventId');
    checkIdNotEmpty(userId, name: 'userId');
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
      () => mapAttendee(requireObject(result.body['attendee'], 'attendee')),
      action: action,
      status: result.status,
    );
  }

  @override
  Future<EventAttendee> removeAttendee(
    String eventId,
    String attendeeId,
  ) async {
    checkPathId(eventId, name: 'eventId');
    checkPathId(attendeeId, name: 'attendeeId');

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
      () => mapAttendee(requireObject(result.body['attendee'], 'attendee')),
      action: action,
      status: result.status,
    );
  }

  @override
  Future<List<OfferedGame>> fetchGamesPool(
    String eventId, {
    List<String>? attendeeIds,
    Future<void>? cancelled,
  }) async {
    checkPathId(eventId, name: 'eventId');
    if (attendeeIds != null) {
      const most = EventRemoteDataSource.maxPoolAttendeeIds;
      if (attendeeIds.length > most) {
        throw ArgumentError.value(
          attendeeIds.length,
          'attendeeIds',
          'names more than $most attendees (the server rejects a longer list '
              'with a 400)',
        );
      }
      for (final attendeeId in attendeeIds) {
        checkIdNotEmpty(attendeeId, name: 'attendeeIds');
      }
      // The server refuses an empty list, and no attendees offer no games.
      if (attendeeIds.isEmpty) return const [];
    }

    // One token for the whole read. However `cancelled` completes, the read
    // stops: Dio fails the request that is out, and no later page is sent.
    final token = CancelToken();
    cancelled?.whenComplete(token.cancel).ignore();

    // A game offered mid-read before a page boundary pushes a row already
    // read onto the next page, which repeats it: the first is kept. One taken
    // back before a boundary pulls a row onto a page already read, so a row
    // still on offer can be skipped until the next read.
    //
    // The path names one event, so an application 404 is the service saying
    // it is gone. Naming an attendee who is not on it narrows to no rows,
    // not a 404.
    return _readAllPages(
      _poolPath(eventId),
      action: 'Offered games',
      key: 'offeredGames',
      noun: 'game',
      item: mapOfferedGame,
      idOf: (game) => game.id,
      query: {
        if (attendeeIds != null) 'attendeeIds': attendeeIds.join(','),
      },
      cancel: token,
    );
  }

  /// Reads [path] from page 1 to the last, [EventRemoteDataSource.maxPageSize]
  /// a page, each row of the envelope's [key] through [item], kept once by
  /// [idOf] in the order first read. [query] goes on every page's request.
  ///
  /// More past the last page the server itself counted, or a page that adds
  /// nothing new, is an envelope that contradicts itself, and nothing else
  /// would stop the read until the server refused a page past its offset
  /// ceiling: either throws [EventRemotePermanentException], naming
  /// [action] and a [noun] for one row.
  ///
  /// [cancel] stops the read: Dio fails the request that is out, and a
  /// cancel that lands as a page is answered sends no later page.
  Future<List<T>> _readAllPages<T>(
    String path, {
    required String action,
    required String key,
    required String noun,
    required T Function(Map<String, dynamic> json) item,
    required String Function(T row) idOf,
    Map<String, Object> query = const {},
    CancelToken? cancel,
  }) async {
    const failures = _EventFailures(_Route.row);
    final all = <String, T>{};
    for (var page = 1; ; page++) {
      final response = await sendForJson(
        () => _dio.get<String>(
          path,
          options: _plainBody,
          queryParameters: {
            'page': page,
            'limit': EventRemoteDataSource.maxPageSize,
            ...query,
          },
          cancelToken: cancel,
        ),
        action: action,
        family: failures,
      );
      final result = parseRemote(
        failures,
        () => PaginatedResult.fromEnvelope(response.body, key: key, item: item),
        action: action,
        status: response.status,
      );
      final before = all.length;
      for (final row in result.items) {
        all.putIfAbsent(idOf(row), () => row);
      }
      if (!result.meta.hasMore) return all.values.toList();

      if (page >= result.meta.totalPages) {
        throw EventRemotePermanentException(
          '$action page $page reports another page past its own last page, '
          '${result.meta.totalPages}',
          statusCode: response.status,
        );
      }
      if (all.length == before) {
        throw EventRemotePermanentException(
          '$action page $page reports another page but adds no $noun not '
          'already read',
          statusCode: response.status,
        );
      }

      // A cancel that landed after this page was answered: what Dio would
      // throw for the next page, without sending it.
      if (cancel?.cancelError case final cancelled?) {
        throw failureForDioException(failures, cancelled, action: action);
      }
    }
  }

  @override
  Future<List<GameOfferResult>> offerGames(
    String eventId,
    String attendeeId, {
    required List<String> collectionIds,
  }) async {
    checkPathId(eventId, name: 'eventId');
    checkPathId(attendeeId, name: 'attendeeId');
    const most = EventRemoteDataSource.maxOfferBatch;
    if (collectionIds.isEmpty || collectionIds.length > most) {
      throw ArgumentError.value(
        collectionIds.length,
        'collectionIds',
        'must hold 1 to $most ids',
      );
    }
    for (final id in collectionIds) {
      checkIdNotEmpty(id, name: 'collectionIds');
    }
    if (collectionIds.toSet().length != collectionIds.length) {
      throw ArgumentError.value(
        collectionIds,
        'collectionIds',
        'must not repeat an id',
      );
    }

    const action = 'Offer games';
    const failures = _EventFailures(_Route.write);
    final result = await sendForJson(
      () => _dio.post<String>(
        '${_offeredGamesPath(eventId, attendeeId)}/batch',
        options: _plainBody,
        data: {
          'items': [
            for (final id in collectionIds) {'collectionId': id},
          ],
        },
      ),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
      () => mapObjects(
        result.body['results'],
        field: 'results',
        item: mapGameOfferResult,
      ),
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
    checkPathId(eventId, name: 'eventId');
    checkPathId(attendeeId, name: 'attendeeId');
    checkPathId(offeredGameId, name: 'offeredGameId');

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
    checkPathId(eventId, name: 'eventId');

    // A nomination created mid-read shifts the offsets of a newest-first
    // list, so a later page can repeat a row an earlier one held: the first
    // is kept. The path names one event, so an application 404 is the
    // service saying it is gone.
    return _readAllPages(
      _nominationsPath(eventId),
      action: 'Nominations',
      key: 'nominations',
      noun: 'nomination',
      item: mapNomination,
      idOf: (nomination) => nomination.id,
    );
  }

  @override
  Future<List<LineupGame>> fetchLineup(String eventId) async {
    checkPathId(eventId, name: 'eventId');

    // The list is ordered by date and then the host's order, and a page is an
    // offset into it. A game added or removed mid-read shifts the rows after
    // it, so a page can repeat a row an earlier one held: the first is kept.
    // The path names one event, so an application 404 is the service saying
    // it is gone.
    return _readAllPages(
      _lineupPath(eventId),
      action: 'Lineup',
      key: 'lineup',
      noun: 'game',
      item: mapLineupGame,
      idOf: (game) => game.id,
    );
  }

  @override
  Future<EventNomination> fetchNomination(
    String eventId,
    String nominationId,
  ) async {
    checkPathId(eventId, name: 'eventId');
    checkPathId(nominationId, name: 'nominationId');

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
      () => mapNomination(
        requireObject(response.body['nomination'], 'nomination'),
      ),
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
    checkPathId(eventId, name: 'eventId');
    checkIdNotEmpty(platformGameId, name: 'platformGameId');
    checkIdNotEmpty(suppliedFromId, name: 'suppliedFromId');
    if (occurrenceId != null) {
      checkIdNotEmpty(occurrenceId, name: 'occurrenceId');
    }

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
      () => mapNomination(
        requireObject(result.body['nomination'], 'nomination'),
      ),
      action: action,
      status: result.status,
    );
  }

  @override
  Future<LineupGame> directAddGame(
    String eventId, {
    required String platformGameId,
    required String suppliedById,
    String? occurrenceId,
    ScheduledGameRole role = ScheduledGameRole.primary,
    String? notes,
    int? maxPlayTime,
  }) async {
    checkPathId(eventId, name: 'eventId');
    checkIdNotEmpty(platformGameId, name: 'platformGameId');
    checkIdNotEmpty(suppliedById, name: 'suppliedById');
    if (occurrenceId != null) {
      checkIdNotEmpty(occurrenceId, name: 'occurrenceId');
    }
    // Before anything is sent: an unknown role has no wire name.
    if (role == ScheduledGameRole.unknown) {
      throw ArgumentError.value(role, 'role', 'has no wire name');
    }
    final isFiller = role == ScheduledGameRole.filler;
    if (isFiller && maxPlayTime != null && maxPlayTime < 1) {
      throw ArgumentError.value(
        maxPlayTime,
        'maxPlayTime',
        'must be at least 1',
      );
    }

    const action = 'Add game to lineup';
    const failures = _EventFailures(_Route.lineupAdd);
    final result = await sendForJson(
      () => _dio.post<String>(
        '${_nominationsPath(eventId)}/direct-add',
        options: _plainBody,
        data: {
          'platformGameId': platformGameId,
          'suppliedById': suppliedById,
          'occurrenceId': ?occurrenceId,
          'role': role.toWire(),
          'notes': ?notes,
          // Only a filler has a time: the server's field is "for Filler role
          // only".
          if (isFiller) 'maxPlayTime': ?maxPlayTime,
        },
      ),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
      () => mapLineupGame(requireObject(result.body['eventGame'], 'eventGame')),
      action: action,
      status: result.status,
    );
  }

  @override
  Future<LineupGame> removeLineupGame(
    String eventId,
    String lineupGameId,
  ) async {
    checkPathId(eventId, name: 'eventId');
    checkPathId(lineupGameId, name: 'lineupGameId');

    const action = 'Remove game from lineup';
    const failures = _EventFailures(_Route.lineupRemove);
    final result = await sendForJson(
      () => _dio.delete<String>(
        '${_lineupPath(eventId)}/${Uri.encodeComponent(lineupGameId)}',
        options: _plainBody,
      ),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
      () => mapLineupGame(
        requireObject(result.body['lineupGame'], 'lineupGame'),
      ),
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
    checkPathId(eventId, name: 'eventId');
    checkPathId(nominationId, name: 'nominationId');
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
    checkPathId(eventId, name: 'eventId');
    checkPathId(nominationId, name: 'nominationId');

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
      () => mapNomination(
        requireObject(result.body['nomination'], 'nomination'),
      ),
      action: action,
      status: result.status,
    );
  }

  @override
  Future<EventNomination> approveNomination(
    String eventId,
    String nominationId,
  ) => _decide(
    eventId,
    nominationId,
    'approve',
    'Approve nomination',
    _decidedNomination,
  );

  @override
  Future<EventNomination> rejectNomination(
    String eventId,
    String nominationId,
  ) => _decide(
    eventId,
    nominationId,
    'reject',
    'Reject nomination',
    _decidedNomination,
  );

  @override
  Future<({EventNomination nomination, NominationResolution resolution})>
  resolveNomination(String eventId, String nominationId) => _decide(
    eventId,
    nominationId,
    'resolve',
    'Resolve nomination',
    (body) => (
      nomination: _decidedNomination(body),
      resolution: mapResolution(
        requireObject(body['resolution'], 'resolution'),
      ),
    ),
  );

  /// `POST .../nominations/:nid/<verb>` for a host's decision, its answer
  /// read by [parse]: `{ message, nomination }`, and a resolve's
  /// `resolution` beside them.
  Future<T> _decide<T>(
    String eventId,
    String nominationId,
    String verb,
    String action,
    T Function(Map<String, dynamic> body) parse,
  ) async {
    checkPathId(eventId, name: 'eventId');
    checkPathId(nominationId, name: 'nominationId');

    const failures = _EventFailures(_Route.write);
    final result = await sendForJson(
      () => _dio.post<String>(
        '${_nominationPath(eventId, nominationId)}/$verb',
        options: _plainBody,
      ),
      action: action,
      family: failures,
    );
    return parseRemote(
      failures,
      () => parse(result.body),
      action: action,
      status: result.status,
    );
  }

  /// The nomination a host's decision answers with.
  EventNomination _decidedNomination(Map<String, dynamic> body) =>
      mapNomination(requireObject(body['nomination'], 'nomination'));

  @override
  Future<AvailabilitySummary> fetchAvailabilitySummary(String eventId) async {
    checkPathId(eventId, name: 'eventId');

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
      () => mapSummary(requireObject(response.body['summary'], 'summary')),
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
    checkPathId(eventId, name: 'eventId');
    checkPathId(occurrenceId, name: 'occurrenceId');

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
      () => mapOccurrence(
        requireObject(response.body['occurrence'], 'occurrence'),
      ),
      action: action,
      status: response.status,
    );
  }

  static String _pathOf(String id) => '$_basePath/${Uri.encodeComponent(id)}';

  static String _occurrencesPath(String eventId) =>
      '${_pathOf(eventId)}/occurrences';

  static String _occurrencePath(String eventId, String occurrenceId) =>
      '${_occurrencesPath(eventId)}/${Uri.encodeComponent(occurrenceId)}';

  static String _poolPath(String eventId) =>
      '${_pathOf(eventId)}/offered-games';

  static String _offeredGamesPath(String eventId, String attendeeId) =>
      '${_pathOf(eventId)}/attendees/${Uri.encodeComponent(attendeeId)}/games';

  static String _nominationsPath(String eventId) =>
      '${_pathOf(eventId)}/nominations';

  static String _lineupPath(String eventId) => '${_pathOf(eventId)}/lineup';

  static String _nominationPath(String eventId, String nominationId) =>
      '${_nominationsPath(eventId)}/${Uri.encodeComponent(nominationId)}';
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
  /// conflict with the event's status as it stands. A nomination's is too,
  /// for a pool row that does not match its game (#517). The vote and the
  /// withdrawal share [_Route.write], and their 400 is the nomination's
  /// status as it stands. The batch offer shares it as well, and its 400 is
  /// only ever the validation pipe's (#851).
  @override
  EventRemoteException? refused(RemoteRefusal refusal) {
    final status = refusal.status;
    final body = refusal.body;
    final message = refusal.message;
    final cause = refusal.cause;
    // A code is read only from the API's own envelope, which every coded
    // refusal arrives in (backend#1260): a bare coded body is not the API's.
    if (!refusal.fromApi) return null;
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
        _Route.gameTakeBack ||
        _Route.nominate ||
        _Route.lineupAdd ||
        _Route.lineupRemove => EventWriteRefusedException(
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
        _Route.gameTakeBack ||
        _Route.nominate ||
        _Route.lineupAdd ||
        _Route.lineupRemove => EventRemoteNotFoundException(
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
            route == _Route.gameTakeBack ||
            route == _Route.nominate ||
            route == _Route.lineupAdd ||
            route == _Route.lineupRemove)) {
      // The user is already on the event, the game still supplies a
      // nomination or a lineup, a nomination's or a direct add's supplier is
      // not attending, or a lineup game's lineup has started (its `code`,
      // `LINEUP_STARTED`). A 409 asking for a retry never gets here: the
      // shared classifier reads it as transient first.
      return EventWriteConflictException(
        message,
        cause: cause,
        statusCode: status,
        apiMessage: apiErrorField(body, 'message'),
        code: apiErrorField(body, 'code'),
      );
    }
    if (status == 400 &&
        (route == _Route.write || route == _Route.nominate) &&
        apiErrorField(body, 'message') != null) {
      return EventWriteConflictException(
        message,
        cause: cause,
        statusCode: status,
        apiMessage: apiErrorField(body, 'message'),
        code: apiErrorField(body, 'code'),
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
  /// event, `GET /api/events/:id/offered-games` (#851), and
  /// `GET /api/events/:id/nominations` with the single nomination under it
  /// (#517), and `GET /api/events/:id/lineup` (#519).
  row,

  /// `POST /api/events`, whose 403 and 404 refuse that create.
  create,

  /// A write to one event, to one of its dates or to one of its nominations:
  /// `DELETE /api/events/:id`, the event status writes (`cancel`, `reopen`,
  /// `archive`, `unarchive`), the date routes under it, a vote included, and
  /// the nomination writes (vote, withdraw, approve, reject and resolve, #517
  /// and #518), and the batch offer,
  /// `POST /api/events/:id/attendees/:aid/games/batch` (#851). Its 403
  /// refuses that write, its 404 says the event, date or nomination is gone,
  /// or for the batch offer the event or the attendee, and its enveloped 400
  /// with one message is a conflict with the row as it stands (#506), for a
  /// status write the event's status and for a nomination write the
  /// nomination's. The event delete is never answered 400. The batch offer's
  /// 400 is always the validation pipe's, with a list of messages, so it is
  /// permanent, and so is its 409 unless it asks for a retry (#851).
  write,

  /// `POST /api/events/:id/attendees` (#510). It maps as [write] does, and
  /// its 404 is the event or the invitee (the service refuses an unknown
  /// user), its 403 a missing right or the invitee's block or preference, and
  /// its enveloped 409 a user already on the event.
  attendeeAdd,

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

  /// `POST /api/events/:id/nominations/direct-add` (#519). Its 403 refuses the
  /// add (the caller's role, or a mode that is not Direct or HostOnly), its
  /// 404 is the event, the date or the pool row gone, its 409 a supplier who
  /// is not attending, and its 400 a pool row that does not match the game or
  /// a value the validation pipe refused: permanent.
  lineupAdd,

  /// `DELETE /api/events/:id/lineup/:lineupGameId` (#520). Its 403 refuses the
  /// removal, its 404 is no such game in the lineup (or one removed a moment
  /// before), and its 409 carries `LINEUP_STARTED`. The server never answers
  /// it 400.
  lineupRemove,
}
