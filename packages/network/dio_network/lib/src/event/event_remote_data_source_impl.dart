import 'package:dio/dio.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../network/api_error_envelope.dart';
import '../network/remote_failure.dart';
import '../network/user_projection.dart';

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
  );

  /// One page of event rows from the list route at [path].
  Future<PaginatedResult<EventSnapshot>> _fetchList(
    String path, {
    required int page,
    required int limit,
    required String action,
    bool includeArchived = false,
  }) async {
    _checkPaging(page: page, limit: limit);

    const failures = _EventFailures(_Route.list);
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
      // deployed, such as on a server older than the events routes.
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
  /// says it was not asked, whatever a row carries.
  static EventSnapshot _mapListRow(Map<String, dynamic> json) => EventSnapshot(
    event: _mapEvent(json),
    occurrences: _mapOccurrences(json['occurrences']),
    policy: _mapPolicy(json['policy']),
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
  /// conflict with the event's status as it stands.
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
        _Route.write => EventWriteRefusedException(
          message,
          cause: cause,
          statusCode: status,
          apiMessage: apiErrorField(body, 'message'),
        ),
        _Route.list || _Route.row => EventRemoteForbiddenException(
          message,
          cause: cause,
          statusCode: status,
        ),
      };
    }
    if (status == 404) {
      return switch (route) {
        _Route.row || _Route.write => EventRemoteNotFoundException(
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
    if (status == 400 &&
        route == _Route.write &&
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

  /// `GET /api/events/:id` and the poll's summary under it, which name one
  /// event.
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
}
