import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bge_test_support/network.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// An occurrence as the backend serializes the Prisma model: every column,
/// the cancellation audit fields included, because the embed is not filtered
/// (#496). The mapper has to ignore what the model leaves out.
Map<String, dynamic> _occurrenceRow({
  String id = 'occ_1',
  String eventId = 'ev_1',
  String? label = 'Saturday Evening',
  String? startDate = '2026-11-07T19:00:00.000Z',
  String? endDate = '2026-11-07T23:00:00.000Z',
  String? location,
  String status = 'Confirmed',
  int sortOrder = 0,
  String? confirmedAt = '2026-10-01T10:31:00.000Z',
  String? declinedAt,
  String? cancelledAt,
  String? cancelledById,
  String? cancelReason,
}) => {
  'id': id,
  'eventId': eventId,
  'label': label,
  'startDate': startDate,
  'endDate': endDate,
  'location': location,
  'status': status,
  'sortOrder': sortOrder,
  'confirmedAt': confirmedAt,
  'declinedAt': declinedAt,
  'cancelledAt': cancelledAt,
  'cancelledById': cancelledById,
  'cancelReason': cancelReason,
  'createdAt': '2026-10-01T10:30:00.000Z',
  'updatedAt': '2026-10-01T10:45:00.000Z',
};

/// An event's policy as the backend serializes the Prisma model: the 18 policy
/// columns, with the keys any of them overrides.
Map<String, dynamic> _policyRow([Map<String, dynamic> overrides = const {}]) =>
    {
      'id': 'pol_1',
      'eventId': 'ev_1',
      'allowMemberInvites': true,
      'allowGuestInvites': false,
      'maxAttendees': 8,
      'restrictToGameCategories': true,
      'requireHostApprovalToJoin': false,
      'allowSpectators': true,
      'maxTotalParticipants': 12,
      'strictCapacity': false,
      'gameAdditionMode': 'RequiresVote',
      'restrictToAttendeePool': true,
      'fillerMaxPlayTime': 45,
      'voteThresholdType': 'Supermajority',
      'voteThresholdValue': 66,
      'voteQuorumType': 'PercentOfAttendees',
      'voteQuorumValue': 50,
      'voteEligibility': 'ConfirmedOnly',
      'interestedWeight': 'AsAbstain',
      'votingWindowHours': 24,
      'createdAt': '2026-10-01T10:30:00.000Z',
      'updatedAt': '2026-10-02T08:00:00.000Z',
      ...overrides,
    };

/// The `user` an attendee embeds, by name and avatar:
/// `{ id, username, profile: { avatarUrl, displayName } | null }`.
Map<String, dynamic> _userRow({
  String id = 'user_ada',
  String username = 'ada',
  Map<String, dynamic>? profile = const {
    'avatarUrl': 'https://cdn.example.com/ada.png',
    'displayName': 'Ada',
  },
}) => {'id': id, 'username': username, 'profile': profile};

/// The `role` an attendee embeds: the join row, with the role nested in it.
Map<String, dynamic> _roleRow(String name) => {
  'id': 'ear_1',
  'eventAttendeeId': 'att_1',
  'roleId': 'role_1',
  'createdAt': '2026-10-01T10:30:00.000Z',
  'updatedAt': '2026-10-01T10:30:00.000Z',
  'role': {'id': 'role_1', 'name': name},
};

/// An attendee as `GET /api/events/:id` serializes it: every column, a guest's
/// email address included, plus the `user` and `role` embeds.
Map<String, dynamic> _attendeeRow({
  String id = 'att_1',
  String? userId = 'user_ada',
  String? guestName,
  String? guestEmail,
  String status = 'Attending',
  Map<String, dynamic>? user,
  Map<String, dynamic>? role,
}) => {
  'id': id,
  'eventId': 'ev_1',
  'userId': userId,
  'guestName': guestName,
  'guestEmail': guestEmail,
  'status': status,
  'invitedById': null,
  'notes': 'Bringing snacks.',
  'rsvpDate': '2026-10-02T09:00:00.000Z',
  'removedAt': null,
  'createdAt': '2026-10-01T10:30:00.000Z',
  'updatedAt': '2026-10-02T09:05:00.000Z',
  'user': user,
  'role': role,
};

/// An event as the backend serializes it: every scalar column of the Prisma
/// model, the ones the data layer does not model included, with its embedded
/// occurrences and policy. [attendees] is added for the detail read alone,
/// because the list serves no roster.
Map<String, dynamic> _eventRow({
  String id = 'ev_1',
  String title = 'Friday Night Brass',
  String status = 'Scheduled',
  String schedulingMode = 'Fixed',
  String type = 'FamilyNight',
  String reach = 'Friends',
  String? householdId = 'hh_1',
  String? image = 'https://cdn.example.com/brass.png',
  String? description = 'Bring the expansions.',
  String? location = "Ada's place",
  String? url = 'https://example.com/brass',
  List<Map<String, dynamic>>? occurrences,
  List<Map<String, dynamic>>? attendees,
  String? cancelReason,
  String? cancelledAt,
}) => {
  'id': id,
  'householdId': householdId,
  'createdById': 'user_ada',
  'cancelledById': null,
  'cancelReason': cancelReason,
  'cancelledAt': cancelledAt,
  'deletedById': null,
  'title': title,
  'status': status,
  'schedulingMode': schedulingMode,
  'image': image,
  'description': description,
  'location': location,
  'url': url,
  'type': type,
  'reach': reach,
  'recurrenceRuleId': null,
  'recurrenceStatus': null,
  'deletedAt': null,
  'createdAt': '2026-10-01T10:30:00.000Z',
  'updatedAt': '2026-10-14T18:00:00.000Z',
  'occurrences':
      occurrences ??
      [
        _occurrenceRow(),
        _occurrenceRow(
          id: 'occ_2',
          label: 'Sunday Brunch',
          startDate: '2026-11-08T10:00:00.000Z',
          endDate: null,
          sortOrder: 1,
        ),
      ],
  'policy': _policyRow(),
  'attendees': ?attendees,
};

Map<String, dynamic> _pagination({
  required int total,
  int page = 1,
  int limit = 100,
  int totalPages = 1,
  bool hasMore = false,
}) => {
  'page': page,
  'limit': limit,
  'total': total,
  'totalPages': totalPages,
  'hasMore': hasMore,
};

/// A `GET /api/events` body.
String _listBody(
  List<Map<String, dynamic>> rows, {
  int page = 1,
  int limit = 100,
  int? total,
  bool hasMore = false,
}) => jsonEncode({
  'events': rows,
  'pagination': _pagination(
    page: page,
    limit: limit,
    total: total ?? rows.length,
    hasMore: hasMore,
  ),
});

/// A `GET /api/events/:id` body.
String _detailBody(Map<String, dynamic> event) => jsonEncode({'event': event});

/// A `POST /api/events` body: the message and the event, with the parts the
/// create reads back.
String _createdBody(Map<String, dynamic> event) =>
    jsonEncode({'message': 'Event created', 'event': event});

/// Nest's rendering of an `HttpException` carrying a message.
String _envelope(int status, String error, String message) =>
    jsonEncode({'statusCode': status, 'message': message, 'error': error});

/// The backend's rendering of a deadlock that outlived its own retry.
String _deadlock() => jsonEncode({
  'statusCode': 409,
  'error': 'Conflict',
  'message': 'The request collided with another; try it again.',
  'code': 'TransactionDeadlockError',
  'retryable': true,
});

/// A vote as `GET /api/events/:id/nominations` serves it, `eligible` marked.
Map<String, dynamic> _voteRow({
  String id = 'v1',
  String attendeeId = 'att_1',
  String voteType = 'For',
  bool eligible = true,
  String? comment,
}) => {
  'id': id,
  'attendeeId': attendeeId,
  'voteType': voteType,
  'priority': 1,
  'comment': comment,
  'eligible': eligible,
};

/// A nomination as the backend serves it: the row's columns and the nested
/// game, nominator, supplying pool row and votes (#517).
Map<String, dynamic> _nominationRow({
  String id = 'n1',
  String? occurrenceId,
  String status = 'Open',
  String? pausedFrom,
  String? votingDeadline,
  String? thumbnail = 'https://cdn.example.com/brass.png',
  bool guest = false,
  List<Map<String, dynamic>> votes = const [],
}) => {
  'id': id,
  'eventId': 'e1',
  'occurrenceId': occurrenceId,
  'platformGameId': 'pg_1',
  'releaseId': null,
  'votingDeadline': votingDeadline,
  'nominatedById': 'att_1',
  'suppliedFromId': 'og_1',
  'status': status,
  'pausedFrom': pausedFrom,
  'createdAt': '2026-11-01T10:00:00.000Z',
  'updatedAt': '2026-11-01T10:00:00.000Z',
  'platformGame': {
    'id': 'pg_1',
    'game': {
      'id': 'game_1',
      'title': 'Brass: Birmingham',
      'thumbnail': thumbnail,
    },
    'platform': {
      'id': 'plat_1',
      'name': 'Tabletop',
      'platformType': 'Physical',
    },
  },
  'nominatedBy': {
    'id': 'att_1',
    'user': guest ? null : {'id': 'u_1', 'username': 'ada'},
  },
  'suppliedFrom': {'id': 'og_1'},
  'votes': votes,
};

/// An offered game as `GET /api/events/:id/offered-games` serves it (#851):
/// the entry, its collection entry's id and medium and nothing else of the
/// owner's row, the platform game with its own players and play time, the
/// game with its base games, what the entry supplies, and its attendee. The
/// add's `entry` is the same row without the attendee.
///
/// The platform game's own pictures, players and play time are null unless
/// given, so the game's stand.
Map<String, dynamic> _offeredRow({
  String id = 'og_1',
  String attendeeId = 'att_1',
  String collectionId = 'col_1',
  String title = 'Brass: Birmingham',
  Object? subtitle = 'Deluxe Edition',
  Object? thumbnail = 'https://cdn.example.com/brass.png',
  Object? image,
  Object? platformThumbnail,
  Object? platformImage,
  Object? medium = 'Physical',
  Object? contentType = 'BaseGame',
  Object? platformType = 'Tabletop',
  int? platformMinPlayers,
  int? platformMaxPlayers,
  int? platformMinPlayTime,
  int? platformMaxPlayTime,
  Object? supplies = const {'nominations': 2, 'lineup': 1},
}) => {
  'id': id,
  'attendeeId': attendeeId,
  'createdAt': '2026-11-01T10:00:00.000Z',
  'collection': {
    'id': collectionId,
    'medium': medium,
    'platformGame': {
      'id': 'pg_1',
      'image': platformImage,
      'thumbnail': platformThumbnail,
      'minPlayers': platformMinPlayers,
      'maxPlayers': platformMaxPlayers,
      'minPlayTime': platformMinPlayTime,
      'maxPlayTime': platformMaxPlayTime,
      'platform': {
        'id': 'plat_1',
        'name': 'Tabletop',
        'slug': 'tabletop',
        'platformType': platformType,
      },
      'game': {
        'id': 'game_1',
        'title': title,
        'subtitle': subtitle,
        'thumbnail': thumbnail,
        'image': image,
        'contentType': contentType,
        'publishYear': 2018,
        'complexity': 3.9,
        'minPlayers': 2,
        'maxPlayers': 4,
        'minPlayTime': 60,
        'maxPlayTime': 120,
        'baseGames': <Object?>[],
      },
    },
  },
  'supplies': supplies,
  'attendee': {
    'id': attendeeId,
    'status': 'Attending',
    'guestName': null,
    'user': {
      'id': 'user_ada',
      'username': 'ada',
      'profile': {'displayName': 'Ada', 'avatarUrl': null},
    },
  },
};

/// A `GET /api/events/:id/offered-games` page. A page that says there is
/// more counts one page past itself, unless [totalPages] says otherwise.
String _offeredGamesBody(
  List<Map<String, dynamic>> rows, {
  int page = 1,
  bool hasMore = false,
  int? totalPages,
}) => jsonEncode({
  'offeredGames': rows,
  'pagination': _pagination(
    page: page,
    total: rows.length,
    totalPages: totalPages ?? (hasMore ? page + 1 : page),
    hasMore: hasMore,
  ),
});

/// One request as the transport received it.
typedef _Sent = ({
  String method,
  String path,
  Map<String, dynamic> query,
  Object? body,
});

/// Answers every request with one canned response, and records what it was
/// sent. [CannedAdapter] can't do the second half.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter(this.body, this.status);

  final String body;
  final int status;
  final List<_Sent> sent = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    Object? requestBody;
    if (requestStream != null) {
      final bytes = await requestStream.expand((chunk) => chunk).toList();
      requestBody = jsonDecode(utf8.decode(bytes));
    }
    sent.add((
      method: options.method,
      path: options.path,
      query: options.queryParameters,
      body: requestBody,
    ));
    return ResponseBody.fromString(
      body,
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// One answer a [_PathAdapter] gives.
typedef _Reply = ({String body, int status});

/// Answers each request from [answer], which may wait or throw, and records
/// each path: for the reads that page (#517, #851).
class _PathAdapter implements HttpClientAdapter {
  _PathAdapter(this.answer);

  final Future<_Reply> Function(RequestOptions options) answer;

  /// Each path, in the order its request started.
  final List<String> paths = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    paths.add(options.path);
    final reply = await answer(options);
    return ResponseBody.fromString(
      reply.body,
      reply.status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  late _RecordingAdapter adapter;

  /// A data source over a real Dio, permissive about status like the
  /// production factories.
  EventRemoteDataSource answering(String body, {int status = 200}) {
    adapter = _RecordingAdapter(body, status);
    final dio = Dio(BaseOptions(validateStatus: (_) => true))
      ..httpClientAdapter = adapter;
    return EventRemoteDataSourceImpl(dio);
  }

  group('fetchEvents', () {
    test(
      'reads each row with its occurrences and policy, and no roster',
      () async {
        final remote = answering(
          _listBody([_eventRow()], total: 7, hasMore: true),
        );

        final page = await remote.fetchEvents();

        final snapshot = page.items.single;
        expect(snapshot.event.title, 'Friday Night Brass');
        expect(snapshot.occurrences.length, 2);
        expect(
          snapshot.policy!.gameAdditionMode,
          GameAdditionMode.requiresVote,
        );
        expect(snapshot.attendees, isNull);
        expect(page.meta.hasMore, isTrue);
        expect(page.meta.total, 7);
      },
    );

    test(
      'maps every field of the event, its occurrences and its policy',
      () async {
        final remote = answering(
          _listBody([
            _eventRow(
              occurrences: [
                _occurrenceRow(location: 'The back room'),
                _occurrenceRow(
                  id: 'occ_2',
                  label: null,
                  startDate: null,
                  endDate: null,
                  status: 'Declined',
                  sortOrder: 1,
                  confirmedAt: null,
                  declinedAt: '2026-10-03T12:00:00.000Z',
                ),
                _occurrenceRow(
                  id: 'occ_3',
                  status: 'Cancelled',
                  sortOrder: 2,
                  cancelledAt: '2026-10-05T09:00:00.000Z',
                  cancelledById: 'user_ada',
                  cancelReason: 'Venue closed',
                ),
              ],
            ),
          ]),
        );

        final snapshot = (await remote.fetchEvents()).items.single;

        expect(
          snapshot.event,
          Event(
            id: 'ev_1',
            title: 'Friday Night Brass',
            createdById: 'user_ada',
            householdId: 'hh_1',
            description: 'Bring the expansions.',
            image: 'https://cdn.example.com/brass.png',
            location: "Ada's place",
            url: 'https://example.com/brass',
            type: EventType.familyNight,
            reach: Reach.friends,
            status: EventStatus.scheduled,
            schedulingMode: EventSchedulingMode.fixed,
            createdAt: DateTime.utc(2026, 10, 1, 10, 30),
            updatedAt: DateTime.utc(2026, 10, 14, 18),
          ),
        );
        expect(snapshot.occurrences, [
          EventOccurrence(
            id: 'occ_1',
            eventId: 'ev_1',
            label: 'Saturday Evening',
            startDate: DateTime.utc(2026, 11, 7, 19),
            endDate: DateTime.utc(2026, 11, 7, 23),
            location: 'The back room',
            status: OccurrenceStatus.confirmed,
            sortOrder: 0,
            confirmedAt: DateTime.utc(2026, 10, 1, 10, 31),
            createdAt: DateTime.utc(2026, 10, 1, 10, 30),
            updatedAt: DateTime.utc(2026, 10, 1, 10, 45),
          ),
          EventOccurrence(
            id: 'occ_2',
            eventId: 'ev_1',
            status: OccurrenceStatus.declined,
            sortOrder: 1,
            declinedAt: DateTime.utc(2026, 10, 3, 12),
            createdAt: DateTime.utc(2026, 10, 1, 10, 30),
            updatedAt: DateTime.utc(2026, 10, 1, 10, 45),
          ),
          EventOccurrence(
            id: 'occ_3',
            eventId: 'ev_1',
            label: 'Saturday Evening',
            startDate: DateTime.utc(2026, 11, 7, 19),
            endDate: DateTime.utc(2026, 11, 7, 23),
            status: OccurrenceStatus.cancelled,
            sortOrder: 2,
            confirmedAt: DateTime.utc(2026, 10, 1, 10, 31),
            cancelledAt: DateTime.utc(2026, 10, 5, 9),
            cancelReason: 'Venue closed',
            createdAt: DateTime.utc(2026, 10, 1, 10, 30),
            updatedAt: DateTime.utc(2026, 10, 1, 10, 45),
          ),
        ]);
        expect(
          snapshot.policy,
          EventPolicy(
            id: 'pol_1',
            eventId: 'ev_1',
            allowMemberInvites: true,
            allowGuestInvites: false,
            maxAttendees: 8,
            restrictToGameCategories: true,
            requireHostApprovalToJoin: false,
            allowSpectators: true,
            maxTotalParticipants: 12,
            strictCapacity: false,
            gameAdditionMode: GameAdditionMode.requiresVote,
            restrictToAttendeePool: true,
            fillerMaxPlayTime: 45,
            voteThresholdType: VoteThresholdType.supermajority,
            voteThresholdValue: 66,
            voteQuorumType: VoteQuorumType.percentOfAttendees,
            voteQuorumValue: 50,
            voteEligibility: VoteEligibility.confirmedOnly,
            interestedWeight: InterestedWeight.asAbstain,
            votingWindowHours: 24,
            createdAt: DateTime.utc(2026, 10, 1, 10, 30),
            updatedAt: DateTime.utc(2026, 10, 2, 8),
          ),
        );
      },
    );

    test("a cancelled event's reason and time are read", () async {
      final remote = answering(
        _listBody([
          _eventRow(
            status: 'Cancelled',
            cancelReason: 'Rain',
            cancelledAt: '2026-11-04T10:00:00.000Z',
          ),
        ]),
      );

      final event = (await remote.fetchEvents()).items.single.event;

      expect(event.cancelReason, 'Rain');
      expect(event.cancelledAt, DateTime.utc(2026, 11, 4, 10));
    });

    test("an event that isn't cancelled reads null for both", () async {
      final present = answering(_listBody([_eventRow()]));
      final presentEvent = (await present.fetchEvents()).items.single.event;
      expect(presentEvent.cancelReason, isNull);
      expect(presentEvent.cancelledAt, isNull);

      final row = _eventRow()
        ..remove('cancelReason')
        ..remove('cancelledAt');
      final absent = answering(_listBody([row]));
      final absentEvent = (await absent.fetchEvents()).items.single.event;
      expect(absentEvent.cancelReason, isNull);
      expect(absentEvent.cancelledAt, isNull);
    });

    test('reads each policy flag from its own key', () async {
      // Two flags with the same value cannot show a swap in one fixture, so
      // each is flipped alone and must be the only one that moves.
      final flags = <String, bool Function(EventPolicy)>{
        'allowMemberInvites': (p) => p.allowMemberInvites,
        'allowGuestInvites': (p) => p.allowGuestInvites,
        'restrictToGameCategories': (p) => p.restrictToGameCategories,
        'requireHostApprovalToJoin': (p) => p.requireHostApprovalToJoin,
        'allowSpectators': (p) => p.allowSpectators,
        'strictCapacity': (p) => p.strictCapacity,
        'restrictToAttendeePool': (p) => p.restrictToAttendeePool,
      };
      final baseline = _policyRow();

      for (final flag in flags.entries) {
        final remote = answering(
          _listBody([
            _eventRow()
              ..['policy'] = _policyRow({
                flag.key: !(baseline[flag.key] as bool),
              }),
          ]),
        );

        final policy = (await remote.fetchEvents()).items.single.policy!;

        for (final other in flags.entries) {
          expect(
            other.value(policy),
            other.key == flag.key
                ? !(baseline[other.key] as bool)
                : baseline[other.key],
            reason: 'flipping ${flag.key}, read through ${other.key}',
          );
        }
      }
    });

    test('maps an event with no household, image, place or link, and a policy '
        'with no limits, to nulls', () async {
      final remote = answering(
        _listBody([
          _eventRow(
              householdId: null,
              image: null,
              description: null,
              location: null,
              url: null,
            )
            ..['policy'] = _policyRow({
              'maxAttendees': null,
              'maxTotalParticipants': null,
              'fillerMaxPlayTime': null,
              'voteThresholdValue': null,
              'voteQuorumValue': null,
              'votingWindowHours': null,
            }),
        ]),
      );

      final snapshot = (await remote.fetchEvents()).items.single;

      expect(snapshot.event.householdId, isNull);
      expect(snapshot.event.image, isNull);
      expect(snapshot.event.description, isNull);
      expect(snapshot.event.location, isNull);
      expect(snapshot.event.url, isNull);
      final policy = snapshot.policy!;
      expect(policy.maxAttendees, isNull);
      expect(policy.maxTotalParticipants, isNull);
      expect(policy.fillerMaxPlayTime, isNull);
      expect(policy.voteThresholdValue, isNull);
      expect(policy.voteQuorumValue, isNull);
      expect(policy.votingWindowHours, isNull);
    });

    test(
      'marks nothing as waiting to sync: the server confirmed the row',
      () async {
        final remote = answering(_listBody([_eventRow()]));

        final event = (await remote.fetchEvents()).items.single.event;

        expect(event.isDirty, isFalse);
        expect(event.isLocalOnly, isFalse);
      },
    );

    test('an event with no policy has a null policy', () async {
      final remote = answering(_listBody([_eventRow()..['policy'] = null]));

      final snapshot = (await remote.fetchEvents()).items.single;

      expect(snapshot.policy, isNull);
      expect(snapshot.occurrences, isNotEmpty);
    });

    test('an event with no occurrences has an empty list of them', () async {
      final remote = answering(_listBody([_eventRow(occurrences: [])]));

      final snapshot = (await remote.fetchEvents()).items.single;

      expect(snapshot.occurrences, isEmpty);
    });

    test('a roster on a row is never read: the list serves none, so '
        'the snapshot says it was not asked', () async {
      final remote = answering(
        _listBody([
          _eventRow(
            attendees: [
              _attendeeRow(user: _userRow(), role: _roleRow('EventHost')),
            ],
          ),
          _eventRow(id: 'ev_2')..['attendees'] = 'not a roster',
        ]),
      );

      final page = await remote.fetchEvents();

      expect(page.items, hasLength(2));
      expect(page.items.map((snapshot) => snapshot.attendees), [null, null]);
    });

    test('an empty page is a page, not a failure', () async {
      final remote = answering(_listBody([]));

      final page = await remote.fetchEvents();

      expect(page.items, isEmpty);
      expect(page.meta.total, 0);
      expect(page.meta.hasMore, isFalse);
    });

    test('asks for the page and limit it was given', () async {
      final remote = answering(_listBody([]));

      await remote.fetchEvents(page: 2, limit: 50);

      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/events');
      expect(adapter.sent.single.query, {'page': 2, 'limit': 50});
    });

    test('sends includeArchived only when asked', () async {
      final remote = answering(_listBody([]));

      await remote.fetchEvents();
      await remote.fetchEvents(includeArchived: true);

      expect(adapter.sent[0].query, {'page': 1, 'limit': 100});
      expect(adapter.sent[1].query, {
        'page': 1,
        'limit': 100,
        'includeArchived': true,
      });
    });

    test('defaults to the first page at the largest size', () async {
      final remote = answering(_listBody([]));

      await remote.fetchEvents();

      expect(adapter.sent.single.query, {'page': 1, 'limit': 100});
    });

    test('refuses a limit above 100 before sending', () async {
      final remote = answering(_listBody([]));

      await expectLater(remote.fetchEvents(limit: 101), throwsArgumentError);
      expect(adapter.sent, isEmpty);
    });

    test('refuses a page before the first, and a limit below one, before '
        'sending', () async {
      final remote = answering(_listBody([]));

      await expectLater(remote.fetchEvents(page: 0), throwsArgumentError);
      await expectLater(remote.fetchEvents(limit: 0), throwsArgumentError);
      expect(adapter.sent, isEmpty);
    });

    test('a 404 on the list route is transient, even from the API', () async {
      // Nest answers a route that is not deployed with this same envelope. A
      // list route is never absent for a caller who reached it, so on a
      // server older than the events routes this is "not deployed", not "no
      // events".
      final remote = answering(
        _envelope(404, 'Not Found', 'Cannot GET /api/events'),
        status: 404,
      );

      await expectLater(
        remote.fetchEvents(limit: 1),
        throwsA(
          isA<EventRemoteTransientException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });
  });

  group('browseEvents', () {
    test('sends GET /api/events/browse with page and limit', () async {
      final remote = answering(_listBody([]));

      await remote.browseEvents(page: 2, limit: 3);

      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/events/browse');
      expect(adapter.sent.single.query, {'page': 2, 'limit': 3});
    });

    test('defaults to the first page at the largest size', () async {
      final remote = answering(_listBody([]));

      await remote.browseEvents();

      expect(adapter.sent.single.query, {'page': 1, 'limit': 100});
    });

    test('parses rows as the list does', () async {
      final remote = answering(_listBody([_eventRow()]));

      final snapshot = (await remote.browseEvents()).items.single;

      expect(snapshot.event.title, 'Friday Night Brass');
      expect(snapshot.occurrences, hasLength(2));
      expect(snapshot.policy!.gameAdditionMode, GameAdditionMode.requiresVote);
      expect(snapshot.attendees, isNull);
    });

    test('reads the pagination envelope under the events key', () async {
      final remote = answering(
        _listBody([_eventRow()], total: 7, hasMore: true),
      );

      final page = await remote.browseEvents(limit: 1);

      expect(page.meta.total, 7);
      expect(page.meta.hasMore, isTrue);
    });

    test('refuses paging out of range before sending', () async {
      final remote = answering(_listBody([]));

      await expectLater(remote.browseEvents(limit: 0), throwsArgumentError);
      await expectLater(remote.browseEvents(limit: 101), throwsArgumentError);
      await expectLater(remote.browseEvents(page: 0), throwsArgumentError);
      expect(adapter.sent, isEmpty);
    });

    test('a 403 from the API is forbidden', () async {
      final remote = answering(
        _envelope(403, 'Forbidden', 'You are not allowed to do that.'),
        status: 403,
      );

      await expectLater(
        remote.browseEvents(limit: 1),
        throwsA(isA<EventRemoteForbiddenException>()),
      );
    });

    test('a 404 is transient, even from the API', () async {
      // As on the list: a server without the route answers with this envelope.
      final remote = answering(
        _envelope(404, 'Not Found', 'Cannot GET /api/events/browse'),
        status: 404,
      );

      await expectLater(
        remote.browseEvents(limit: 1),
        throwsA(
          isA<EventRemoteTransientException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });

    test('a failure names the browse, not the list', () async {
      final remote = answering('', status: 500);

      await expectLater(
        remote.browseEvents(limit: 1),
        throwsA(
          isA<EventRemoteTransientException>().having(
            (e) => e.message,
            'message',
            contains('Event browse'),
          ),
        ),
      );
    });
  });

  group('fetchHouseholdEvents', () {
    test("requests the household's route with page and limit", () async {
      final remote = answering(_listBody([]));

      await remote.fetchHouseholdEvents('h/1', page: 2, limit: 50);

      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/households/h%2F1/events');
      expect(adapter.sent.single.query, {'page': 2, 'limit': 50});
    });

    test('reads rows as list rows', () async {
      final remote = answering(
        _listBody([
          _eventRow()
            ..['attendance'] = {
              'attendeeId': 'a1',
              'status': 'Maybe',
              'role': 'EventGuest',
              'rsvpDate': null,
            },
        ]),
      );

      final snapshot = (await remote.fetchHouseholdEvents('h1')).items.single;

      expect(snapshot.attendees, isNull);
      expect(
        snapshot.attendance,
        const EventAttendance(
          attendeeId: 'a1',
          status: EventParticipationStatus.maybe,
          role: EventRole.guest,
        ),
      );
    });

    test('a 404 with the envelope is not found', () async {
      final remote = answering(
        _envelope(404, 'Not Found', 'Household not found'),
        status: 404,
      );

      await expectLater(
        remote.fetchHouseholdEvents('h1'),
        throwsA(isA<EventRemoteNotFoundException>()),
      );
    });

    test('a 404 without it is transient', () async {
      final remote = answering('', status: 404);

      await expectLater(
        remote.fetchHouseholdEvents('h1'),
        throwsA(isA<EventRemoteTransientException>()),
      );
    });

    test('a 403 with the envelope is forbidden', () async {
      final remote = answering(
        _envelope(403, 'Forbidden', 'You are not allowed to do that.'),
        status: 403,
      );

      await expectLater(
        remote.fetchHouseholdEvents('h1'),
        throwsA(isA<EventRemoteForbiddenException>()),
      );
    });

    test('rejects a limit out of range before sending', () async {
      final remote = answering(_listBody([]));

      await expectLater(
        remote.fetchHouseholdEvents('h1', limit: 101),
        throwsArgumentError,
      );
      await expectLater(
        remote.fetchHouseholdEvents('h1', limit: 0),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });
  });

  group('fetchEvent', () {
    test('reads the event with its roster', () async {
      final remote = answering(
        _detailBody(
          _eventRow(
            attendees: [
              _attendeeRow(user: _userRow(), role: _roleRow('EventHost')),
            ],
          ),
        ),
      );

      final snapshot = await remote.fetchEvent('ev_1');

      expect(adapter.sent.single.method, 'GET');
      expect(adapter.sent.single.path, '/api/events/ev_1');
      expect(adapter.sent.single.query, isEmpty);
      expect(snapshot.event.id, 'ev_1');
      expect(snapshot.occurrences.length, 2);
      expect(snapshot.policy!.gameAdditionMode, GameAdditionMode.requiresVote);
      expect(snapshot.attendees!.single.role, EventRole.host);
      expect(snapshot.attendees!.single.displayName, 'Ada');
      expect(snapshot.attendees, [
        EventAttendee(
          id: 'att_1',
          eventId: 'ev_1',
          userId: 'user_ada',
          username: 'ada',
          displayName: 'Ada',
          avatarUrl: 'https://cdn.example.com/ada.png',
          notes: 'Bringing snacks.',
          status: EventParticipationStatus.attending,
          role: EventRole.host,
          rsvpDate: DateTime.utc(2026, 10, 2, 9),
          createdAt: DateTime.utc(2026, 10, 1, 10, 30),
          updatedAt: DateTime.utc(2026, 10, 2, 9, 5),
        ),
      ]);
    });

    test('an account that has set no profile has a username and nothing '
        'else of its own', () async {
      final remote = answering(
        _detailBody(
          _eventRow(
            attendees: [
              _attendeeRow(
                user: _userRow(profile: null),
                role: _roleRow('EventParticipant'),
              ),
              _attendeeRow(
                id: 'att_2',
                user: _userRow(
                  profile: {'avatarUrl': null, 'displayName': null},
                ),
                role: _roleRow('EventParticipant'),
              ),
            ],
          ),
        ),
      );

      final roster = (await remote.fetchEvent('ev_1')).attendees!;

      for (final attendee in roster) {
        expect(attendee.username, 'ada');
        expect(attendee.displayName, isNull);
        expect(attendee.avatarUrl, isNull);
        expect(attendee.isGuest, isFalse);
      }
    });

    test('an empty roster reads as empty, not absent', () async {
      // A caller who may not read the roster is served `attendees: []`, which
      // is not the same as nobody being on the event.
      final remote = answering(_detailBody(_eventRow(attendees: [])));

      final snapshot = await remote.fetchEvent('ev_1');

      expect(snapshot.attendees, isNotNull);
      expect(snapshot.attendees, isEmpty);
    });

    test('maps a date still to be set and a guest attendee', () async {
      final remote = answering(
        _detailBody(
          _eventRow(
            schedulingMode: 'Poll',
            status: 'Planning',
            occurrences: [
              _occurrenceRow(
                label: null,
                startDate: null,
                endDate: null,
                status: 'Proposed',
                confirmedAt: null,
              ),
            ],
            attendees: [
              _attendeeRow(
                id: 'att_2',
                userId: null,
                guestName: 'Sam',
                guestEmail: 'sam@example.com',
                status: 'Invited',
                role: _roleRow('EventGuest'),
              ),
            ],
          ),
        ),
      );

      final snapshot = await remote.fetchEvent('ev_1');

      final occurrence = snapshot.occurrences.single;
      expect(occurrence.startDate, isNull);
      expect(occurrence.endDate, isNull);
      expect(occurrence.label, isNull);
      expect(occurrence.status, OccurrenceStatus.proposed);
      final guest = snapshot.attendees!.single;
      expect(guest.isGuest, isTrue);
      expect(guest.userId, isNull);
      expect(guest.guestName, 'Sam');
      expect(guest.username, isNull);
      expect(guest.displayName, isNull);
      expect(guest.avatarUrl, isNull);
      expect(guest.status, EventParticipationStatus.invited);
      expect(guest.role, EventRole.guest);
    });

    test(
      "never carries a guest's email address into the roster (#496)",
      () async {
        final remote = answering(
          _detailBody(
            _eventRow(
              attendees: [
                _attendeeRow(
                  userId: null,
                  guestName: 'Sam',
                  guestEmail: 'sam@example.com',
                ),
              ],
            ),
          ),
        );

        final snapshot = await remote.fetchEvent('ev_1');

        expect(
          snapshot.attendees.toString(),
          isNot(contains('sam@example.com')),
        );
      },
    );

    test('an attendee with no role binding has no role', () async {
      final remote = answering(
        _detailBody(
          _eventRow(attendees: [_attendeeRow(user: _userRow())]),
        ),
      );

      final snapshot = await remote.fetchEvent('ev_1');

      expect(snapshot.attendees!.single.role, isNull);
    });

    test('an unknown status and role read as unknown', () async {
      final remote = answering(
        _detailBody(
          _eventRow(
            status: 'Postponed',
            attendees: [
              _attendeeRow(
                user: _userRow(),
                role: _roleRow('EventScorekeeper'),
              ),
            ],
          ),
        ),
      );

      final snapshot = await remote.fetchEvent('ev_1');

      expect(snapshot.event.status, EventStatus.unknown);
      expect(snapshot.attendees!.single.role, EventRole.unknown);
    });

    test('every enum reads as unknown when a newer server adds a value, '
        'rather than failing the event', () async {
      final remote = answering(
        _detailBody(
          _eventRow(
              status: 'Postponed',
              schedulingMode: 'Recurring',
              type: 'Tournament',
              reach: 'Galaxy',
              occurrences: [_occurrenceRow(status: 'Rescheduled')],
              attendees: [
                _attendeeRow(
                  status: 'Waitlisted',
                  user: _userRow(),
                  role: _roleRow('EventScorekeeper'),
                ),
              ],
            )
            ..['policy'] = _policyRow({
              'gameAdditionMode': 'Auction',
              'voteThresholdType': 'Quadratic',
              'voteQuorumType': 'Weighted',
              'voteEligibility': 'Veterans',
              'interestedWeight': 'AsHalf',
            }),
        ),
      );

      final snapshot = await remote.fetchEvent('ev_1');

      expect(snapshot.event.status, EventStatus.unknown);
      expect(snapshot.event.schedulingMode, EventSchedulingMode.unknown);
      expect(snapshot.event.type, EventType.unknown);
      expect(snapshot.event.reach, Reach.unknown);
      expect(snapshot.occurrences.single.status, OccurrenceStatus.unknown);
      final attendee = snapshot.attendees!.single;
      expect(attendee.status, EventParticipationStatus.unknown);
      expect(attendee.role, EventRole.unknown);
      final policy = snapshot.policy!;
      expect(policy.gameAdditionMode, GameAdditionMode.unknown);
      expect(policy.voteThresholdType, VoteThresholdType.unknown);
      expect(policy.voteQuorumType, VoteQuorumType.unknown);
      expect(policy.voteEligibility, VoteEligibility.unknown);
      expect(policy.interestedWeight, InterestedWeight.unknown);
    });

    test('an event the caller may not read the policy of has a null policy, '
        'as one with none has', () async {
      final remote = answering(
        _detailBody(_eventRow(attendees: [])..['policy'] = null),
      );

      final snapshot = await remote.fetchEvent('ev_1');

      expect(snapshot.policy, isNull);
      expect(snapshot.attendees, isEmpty);
    });

    test('encodes the id into the path', () async {
      final remote = answering(
        _detailBody(_eventRow(id: 'a/b', attendees: [])),
      );

      await remote.fetchEvent('a/b');

      expect(adapter.sent.single.path, '/api/events/a%2Fb');
    });

    test('refuses an empty id before sending', () async {
      // `GET /api/events/` reaches the list route, whose 200 would fail to
      // parse as a detail and read as a server fault.
      final remote = answering(_detailBody(_eventRow(attendees: [])));

      await expectLater(remote.fetchEvent(''), throwsArgumentError);
      expect(adapter.sent, isEmpty);
    });

    test('a 404 from the API means the event is gone or unreadable', () async {
      // The server answers an event that does not exist, one deleted, and one
      // the caller may not read in the same way.
      final remote = answering(
        _envelope(404, 'Not Found', 'Event ev_1 was not found.'),
        status: 404,
      );

      await expectLater(
        remote.fetchEvent('ev_1'),
        throwsA(
          isA<EventRemoteNotFoundException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });

    test('a 404 without the envelope is transient', () async {
      // A proxy or gateway answered, not the API, so nothing is known about
      // the event.
      final remote = answering('<html>Not Found</html>', status: 404);

      await expectLater(
        remote.fetchEvent('ev_1'),
        throwsA(isA<EventRemoteTransientException>()),
      );
    });
  });

  group('a 2xx body this contract cannot read is permanent', () {
    Future<void> expectPermanent(Future<Object?> read) => expectLater(
      read,
      throwsA(
        isA<EventRemotePermanentException>().having(
          (e) => e.statusCode,
          'statusCode',
          200,
        ),
      ),
    );

    test('a list under another key', () async {
      final remote = answering(
        jsonEncode({
          'households': [_eventRow()],
          'pagination': _pagination(total: 1),
        }),
      );

      await expectPermanent(remote.fetchEvents());
    });

    test('a row that cannot be mapped', () async {
      final remote = answering(_listBody([_eventRow()..remove('title')]));

      await expectPermanent(remote.fetchEvents());
    });

    test('a list row without its occurrences', () async {
      final remote = answering(_listBody([_eventRow()..remove('occurrences')]));

      await expectPermanent(remote.fetchEvents());
    });

    test('a list row whose occurrences are not a list', () async {
      final remote = answering(
        _listBody([_eventRow()..['occurrences'] = 'Saturday']),
      );

      await expectPermanent(remote.fetchEvents());
    });

    test('a policy that is neither an object nor null', () async {
      final remote = answering(_listBody([_eventRow()..['policy'] = 'strict']));

      await expectPermanent(remote.fetchEvents());
    });

    test('a detail body with no event object', () async {
      // The list envelope is what a path that fell through to the list route
      // answers with.
      final remote = answering(_listBody([_eventRow()]));

      await expectPermanent(remote.fetchEvent('ev_1'));
    });

    test('a detail body whose event is null', () async {
      final remote = answering(jsonEncode({'event': null}));

      await expectPermanent(remote.fetchEvent('ev_1'));
    });

    test('a detail body whose event is not an object', () async {
      final remote = answering(jsonEncode({'event': 'ev_1'}));

      await expectPermanent(remote.fetchEvent('ev_1'));
    });

    test('a detail event without its roster: the roster is never null, so '
        'a missing one is not "nobody"', () async {
      final remote = answering(
        _detailBody(_eventRow(attendees: [])..remove('attendees')),
      );

      await expectPermanent(remote.fetchEvent('ev_1'));
    });

    test('a detail event whose roster is not a list', () async {
      for (final roster in [null, 'nobody', <String, dynamic>{}]) {
        final remote = answering(
          _detailBody(_eventRow(attendees: [])..['attendees'] = roster),
        );

        await expectPermanent(remote.fetchEvent('ev_1'));
      }
    });

    test('a detail event without its occurrences', () async {
      final remote = answering(
        _detailBody(_eventRow(attendees: [])..remove('occurrences')),
      );

      await expectPermanent(remote.fetchEvent('ev_1'));
    });

    test('a roster entry that is not an object', () async {
      final remote = answering(
        _detailBody(_eventRow(attendees: [])..['attendees'] = ['att_1']),
      );

      await expectPermanent(remote.fetchEvent('ev_1'));
    });

    test('a role projection of the wrong shape, which is not an unknown '
        'role', () async {
      // Laundering a shape error into `unknown` would make a parsing failure
      // look like a custom server role.
      final entries = <Map<String, dynamic>>[
        // The projection is not an object.
        _attendeeRow(user: _userRow())..['role'] = 'EventHost',
        // The nested role is missing.
        _attendeeRow(user: _userRow())..['role'] = {'id': 'ear_1'},
        // The nested role has no name.
        _attendeeRow(user: _userRow())
          ..['role'] = {
            'id': 'ear_1',
            'role': {'id': 'role_1'},
          },
      ];

      for (final entry in entries) {
        final remote = answering(_detailBody(_eventRow(attendees: [entry])));

        await expectPermanent(remote.fetchEvent('ev_1'));
      }
    });

    test(
      'an attendee whose account or profile is of the wrong shape',
      () async {
        final entries = <Map<String, dynamic>>[
          _attendeeRow(role: _roleRow('EventHost'))..['user'] = 'ada',
          _attendeeRow(
            role: _roleRow('EventHost'),
            user: _userRow()..['profile'] = 'Ada',
          ),
          _attendeeRow(
            role: _roleRow('EventHost'),
            user: _userRow()..remove('username'),
          ),
        ];

        for (final entry in entries) {
          final remote = answering(_detailBody(_eventRow(attendees: [entry])));

          await expectPermanent(remote.fetchEvent('ev_1'));
        }
      },
    );
  });

  group('createEvent', () {
    /// The create's answer for a host alone: the roster carries the role
    /// embed and no `user`, as `POST /events` reads it back.
    Map<String, dynamic> created() =>
        _eventRow(attendees: [_attendeeRow(role: _roleRow('EventHost'))]);

    Future<CreatedEvent> create(EventRemoteDataSource remote) =>
        remote.createEvent(const EventDraft(title: 'T'), clientRequestId: 'k');

    test('posts the draft keyed by its clientRequestId', () async {
      final remote = answering(_createdBody(created()), status: 201);

      await remote.createEvent(
        EventDraft(
          title: 'Game night',
          schedulingMode: EventSchedulingMode.poll,
          occurrences: [
            EventOccurrenceDraft(
              label: 'Sat',
              startDate: DateTime.utc(2026, 11, 1, 18),
            ),
            EventOccurrenceDraft(startDate: DateTime.utc(2026, 11, 2, 18)),
          ],
          policy: const EventPolicyDraft(
            gameAdditionMode: GameAdditionMode.requiresVote,
            votingWindowHours: 48,
          ),
          inviteUserIds: const ['u-2'],
        ),
        clientRequestId: 'local-1',
      );

      expect(adapter.sent.single.method, 'POST');
      expect(adapter.sent.single.path, '/api/events');
      expect(adapter.sent.single.query, isEmpty);
      expect(adapter.sent.single.body, {
        'title': 'Game night',
        'clientRequestId': 'local-1',
        'schedulingMode': 'Poll',
        'occurrences': [
          {
            'label': 'Sat',
            'startDate': '2026-11-01T18:00:00.000Z',
            'sortOrder': 0,
          },
          {'startDate': '2026-11-02T18:00:00.000Z', 'sortOrder': 1},
        ],
        'policy': {'gameAdditionMode': 'RequiresVote', 'votingWindowHours': 48},
        'inviteUserIds': ['u-2'],
      });
    });

    test('sends every field the draft sets, in UTC', () async {
      final remote = answering(_createdBody(created()), status: 201);

      await remote.createEvent(
        EventDraft(
          title: 'Brass',
          householdId: 'hh_1',
          description: 'Bring the expansions.',
          location: "Ada's place",
          url: 'https://example.com/brass',
          type: EventType.familyNight,
          reach: Reach.friendsOfFriends,
          occurrences: [
            EventOccurrenceDraft(
              // An offset instant goes out as the same instant in UTC.
              startDate: DateTime.parse('2026-11-01T20:00:00+02:00'),
              endDate: DateTime.utc(2026, 11, 1, 22),
              location: 'The garage',
            ),
          ],
          policy: const EventPolicyDraft(
            gameAdditionMode: GameAdditionMode.requiresVote,
            voteThresholdType: VoteThresholdType.supermajority,
            voteThresholdValue: 66,
            voteQuorumType: VoteQuorumType.percentOfAttendees,
            voteQuorumValue: 50,
            votingWindowHours: 24,
          ),
        ),
        clientRequestId: 'k',
      );

      expect(adapter.sent.single.body, {
        'title': 'Brass',
        'clientRequestId': 'k',
        'schedulingMode': 'Fixed',
        'householdId': 'hh_1',
        'description': 'Bring the expansions.',
        'location': "Ada's place",
        'url': 'https://example.com/brass',
        'type': 'FamilyNight',
        'reach': 'FriendsOfFriends',
        'occurrences': [
          {
            'startDate': '2026-11-01T18:00:00.000Z',
            'endDate': '2026-11-01T22:00:00.000Z',
            'location': 'The garage',
            'sortOrder': 0,
          },
        ],
        'policy': {
          'gameAdditionMode': 'RequiresVote',
          'voteThresholdType': 'Supermajority',
          'voteThresholdValue': 66,
          'voteQuorumType': 'PercentOfAttendees',
          'voteQuorumValue': 50,
          'votingWindowHours': 24,
        },
      });
    });

    test('an empty draft sends only its title, key and mode', () async {
      final remote = answering(_createdBody(created()), status: 201);

      await create(remote);

      expect(adapter.sent.single.body, {
        'title': 'T',
        'clientRequestId': 'k',
        'schedulingMode': 'Fixed',
      });
    });

    test('a created event is read with its roster', () async {
      final remote = answering(_createdBody(created()), status: 201);

      final result = await create(remote);

      final snapshot = result.snapshot;
      expect(snapshot.event.id, 'ev_1');
      expect(snapshot.occurrences.length, 2);
      expect(snapshot.policy!.gameAdditionMode, GameAdditionMode.requiresVote);
      expect(snapshot.attendees!.single.role, EventRole.host);
      expect(snapshot.attendees!.single.userId, 'user_ada');
      expect(result.deletedAt, isNull);
    });

    test('a replay of a deleted event carries deletedAt', () async {
      final remote = answering(
        _createdBody(created()..['deletedAt'] = '2026-10-20T12:30:00.000Z'),
        status: 201,
      );

      final result = await create(remote);

      expect(result.deletedAt, DateTime.utc(2026, 10, 20, 12, 30));
      expect(result.snapshot.event.id, 'ev_1');
    });

    test('an enveloped 403 refuses the create', () async {
      final remote = answering(
        _envelope(403, 'Forbidden', 'You may not create events there.'),
        status: 403,
      );

      await expectLater(
        create(remote),
        throwsA(
          isA<EventCreateRefusedException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having(
                (e) => e.apiMessage,
                'apiMessage',
                'You may not create events there.',
              ),
        ),
      );
    });

    test('an enveloped 404 refuses the create', () async {
      final remote = answering(
        _envelope(404, 'Not Found', 'No such household.'),
        status: 404,
      );

      await expectLater(
        create(remote),
        throwsA(
          isA<EventCreateRefusedException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });

    // The server's own words, which name an invitee it has no account for
    // (#499). The exception's message is this client's, and names no one.
    test("an enveloped 404 on the create carries the envelope's message as "
        'apiMessage', () async {
      final remote = answering(
        _envelope(404, 'Not Found', 'User with ID u-2 not found'),
        status: 404,
      );

      await expectLater(
        create(remote),
        throwsA(
          isA<EventCreateRefusedException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having(
                (e) => e.apiMessage,
                'apiMessage',
                'User with ID u-2 not found',
              ),
        ),
      );
    });

    test('a 403 without the envelope is transient', () async {
      final remote = answering(
        '<html>Blocked by corporate proxy</html>',
        status: 403,
      );

      await expectLater(
        create(remote),
        throwsA(isA<EventRemoteTransientException>()),
      );
    });

    test('a 404 without the envelope is transient', () async {
      final remote = answering('<html>Not Found</html>', status: 404);

      await expectLater(
        create(remote),
        throwsA(isA<EventRemoteTransientException>()),
      );
    });

    test('a 400 is permanent', () async {
      final remote = answering(
        _envelope(400, 'Bad Request', 'title must be a string'),
        status: 400,
      );

      await expectLater(
        create(remote),
        throwsA(
          isA<EventRemotePermanentException>().having(
            (e) => e.statusCode,
            'statusCode',
            400,
          ),
        ),
      );
    });

    test('a 5xx is transient', () async {
      final remote = answering(
        _envelope(503, 'Service Unavailable', 'Try again.'),
        status: 503,
      );

      await expectLater(
        create(remote),
        throwsA(
          isA<EventRemoteTransientException>().having(
            (e) => e.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
    });

    test('a 409 asking for a retry is transient', () async {
      final remote = answering(_deadlock(), status: 409);

      await expectLater(
        create(remote),
        throwsA(isA<EventRemoteTransientException>()),
      );
    });

    test('a 201 with no roster is permanent', () async {
      final remote = answering(
        _createdBody(_eventRow()..remove('attendees')),
        status: 201,
      );

      await expectLater(
        create(remote),
        throwsA(
          isA<EventRemotePermanentException>().having(
            (e) => e.statusCode,
            'statusCode',
            201,
          ),
        ),
      );
    });

    group('requests the server would refuse are never sent', () {
      Future<void> expectRefused(
        EventDraft draft, {
        String clientRequestId = 'k',
      }) async {
        final remote = answering(_createdBody(created()), status: 201);

        await expectLater(
          remote.createEvent(draft, clientRequestId: clientRequestId),
          throwsA(isA<ArgumentError>()),
        );
        expect(adapter.sent, isEmpty);
      }

      test('a blank clientRequestId', () async {
        await expectRefused(const EventDraft(title: 'T'), clientRequestId: '');
        await expectRefused(
          const EventDraft(title: 'T'),
          clientRequestId: '   ',
        );
      });

      test('a clientRequestId of 129 characters', () async {
        await expectRefused(
          const EventDraft(title: 'T'),
          clientRequestId: 'k' * 129,
        );
      });

      test('a clientRequestId of 128 characters is sent', () async {
        final remote = answering(_createdBody(created()), status: 201);

        await remote.createEvent(
          const EventDraft(title: 'T'),
          clientRequestId: 'k' * 128,
        );

        expect(adapter.sent, hasLength(1));
      });

      test('51 invitees', () async {
        await expectRefused(
          EventDraft(
            title: 'T',
            inviteUserIds: [for (var i = 0; i < 51; i++) 'u-$i'],
          ),
        );
      });

      test('50 invitees are sent', () async {
        final remote = answering(_createdBody(created()), status: 201);

        await remote.createEvent(
          EventDraft(
            title: 'T',
            inviteUserIds: [for (var i = 0; i < 50; i++) 'u-$i'],
          ),
          clientRequestId: 'k',
        );

        expect(adapter.sent, hasLength(1));
      });

      test('an unknown event type', () async {
        await expectRefused(
          const EventDraft(title: 'T', type: EventType.unknown),
        );
      });

      test('an unknown reach', () async {
        await expectRefused(const EventDraft(title: 'T', reach: Reach.unknown));
      });

      test('an unknown scheduling mode', () async {
        await expectRefused(
          const EventDraft(
            title: 'T',
            schedulingMode: EventSchedulingMode.unknown,
          ),
        );
      });

      test('an unknown game addition mode in the policy', () async {
        await expectRefused(
          const EventDraft(
            title: 'T',
            policy: EventPolicyDraft(
              gameAdditionMode: GameAdditionMode.unknown,
            ),
          ),
        );
      });

      test('an unknown vote threshold or quorum in the policy', () async {
        await expectRefused(
          const EventDraft(
            title: 'T',
            policy: EventPolicyDraft(
              voteThresholdType: VoteThresholdType.unknown,
            ),
          ),
        );
        await expectRefused(
          const EventDraft(
            title: 'T',
            policy: EventPolicyDraft(voteQuorumType: VoteQuorumType.unknown),
          ),
        );
      });
    });
  });

  group('deleteEvent', () {
    /// The body `DELETE /api/events/:id` answers with, `{ message, event }`,
    /// which the delete does not read (#501).
    String deletedBody() => jsonEncode({
      'message': 'Event deleted',
      'event': _eventRow()..['deletedAt'] = '2026-10-20T12:30:00.000Z',
    });

    test('sends DELETE to the encoded id', () async {
      final remote = answering(deletedBody());

      await remote.deleteEvent('ev 1');

      expect(adapter.sent.single.method, 'DELETE');
      expect(adapter.sent.single.path, '/api/events/ev%201');
      expect(adapter.sent.single.query, isEmpty);
      expect(adapter.sent.single.body, isNull);
    });

    test('a 200 is a delete, whatever its body', () async {
      // The body is not read, so one this client could not map is still a
      // delete that happened.
      await answering(deletedBody()).deleteEvent('ev_1');
      await answering(jsonEncode({'message': 'x', 'event': 'not an event'}))
          .deleteEvent('ev_1');
      await answering('').deleteEvent('ev_1');
      await answering('<html>not json</html>').deleteEvent('ev_1');
      await answering('[]').deleteEvent('ev_1');
    });

    test('any 2xx is a delete, not only 200', () async {
      await answering('', status: 204).deleteEvent('ev_1');
    });

    test('refuses an empty id before sending', () async {
      final remote = answering(deletedBody());

      await expectLater(remote.deleteEvent(''), throwsArgumentError);
      expect(adapter.sent, isEmpty);
    });

    test('an enveloped 404 means the event is gone', () async {
      // A second delete of one event answers this too, and so does an event
      // the caller may not read: the server does not say which.
      final remote = answering(
        _envelope(404, 'Not Found', 'Event not found'),
        status: 404,
      );

      await expectLater(
        remote.deleteEvent('ev_1'),
        throwsA(
          isA<EventRemoteNotFoundException>().having(
            (e) => e.statusCode,
            'statusCode',
            404,
          ),
        ),
      );
    });

    test('an enveloped 403 is a refused write', () async {
      final remote = answering(
        _envelope(403, 'Forbidden', 'You may not delete this event.'),
        status: 403,
      );

      await expectLater(
        remote.deleteEvent('ev_1'),
        throwsA(
          isA<EventWriteRefusedException>()
              .having((e) => e.statusCode, 'statusCode', 403)
              .having(
                (e) => e.apiMessage,
                'apiMessage',
                'You may not delete this event.',
              ),
        ),
      );
    });

    test('a 403 or 404 without the envelope is transient', () async {
      for (final status in [403, 404]) {
        final remote = answering(
          '<html>Blocked by a proxy</html>',
          status: status,
        );

        await expectLater(
          remote.deleteEvent('ev_1'),
          throwsA(
            isA<EventRemoteTransientException>().having(
              (e) => e.statusCode,
              'statusCode',
              status,
            ),
          ),
          reason: 'status $status',
        );
      }
    });

    test('a 5xx is transient', () async {
      final remote = answering(
        _envelope(503, 'Service Unavailable', 'Try again.'),
        status: 503,
      );

      await expectLater(
        remote.deleteEvent('ev_1'),
        throwsA(
          isA<EventRemoteTransientException>().having(
            (e) => e.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
    });

    test('a 400 without the envelope is permanent', () async {
      // With it a 400 on this route reads as a write conflict (#506), which
      // the server never answers a delete with.
      final remote = answering('<html>Bad Request</html>', status: 400);

      await expectLater(
        remote.deleteEvent('ev_1'),
        throwsA(
          isA<EventRemotePermanentException>().having(
            (e) => e.statusCode,
            'statusCode',
            400,
          ),
        ),
      );
    });

    test('an unreachable server is transient', () async {
      final remote = EventRemoteDataSourceImpl(
        unreachableDio(DioExceptionType.connectionError),
      );

      await expectLater(
        remote.deleteEvent('ev_1'),
        throwsA(isA<EventRemoteTransientException>()),
      );
    });
  });

  group('status writes (#502)', () {
    // The row alone, with its status: a status write answers no dates and
    // no policy.
    String statusBody(String status) => jsonEncode({
      'message': 'ok',
      'event': _eventRow(status: status)
        ..remove('occurrences')
        ..remove('policy'),
    });

    final calls =
        <String, (String, Future<Event> Function(EventRemoteDataSource))>{
          'cancel': ('Cancelled', (r) => r.cancelEvent('ev 1')),
          'reopen': ('Scheduled', (r) => r.reopenEvent('ev 1')),
          'archive': ('Archived', (r) => r.archiveEvent('ev 1')),
          'unarchive': ('Scheduled', (r) => r.unarchiveEvent('ev 1')),
        };

    for (final entry in calls.entries) {
      test('${entry.key}Event POSTs /api/events/:id/${entry.key} and returns '
          'the event', () async {
        final remote = answering(statusBody(entry.value.$1));

        final event = await entry.value.$2(remote);

        expect(adapter.sent.single.method, 'POST');
        expect(adapter.sent.single.path, '/api/events/ev%201/${entry.key}');
        expect(event.id, 'ev_1');
        expect(
          event.status,
          EventStatus.values.byName(entry.value.$1.toLowerCase()),
        );
      });
    }

    test(
      'cancelEvent sends the trimmed reason, and {} when it is blank',
      () async {
        final remote = answering(statusBody('Cancelled'));

        await remote.cancelEvent('ev_1', reason: '  Rain  ');
        await remote.cancelEvent('ev_1', reason: '   ');
        await remote.cancelEvent('ev_1');

        expect(adapter.sent[0].body, {'reason': 'Rain'});
        expect(adapter.sent[1].body, <String, dynamic>{});
        expect(adapter.sent[2].body, <String, dynamic>{});
      },
    );

    test(
      'cancelEvent takes 1000 emoji and refuses 1001 before sending',
      () async {
        final remote = answering(statusBody('Cancelled'));

        await remote.cancelEvent('ev_1', reason: '😀' * 1000);
        expect(adapter.sent.single.body, {'reason': '😀' * 1000});

        await expectLater(
          remote.cancelEvent('ev_1', reason: '😀' * 1001),
          throwsArgumentError,
        );
        expect(adapter.sent, hasLength(1));
      },
    );

    test('an empty id is refused before sending', () async {
      final remote = answering(statusBody('Archived'));

      await expectLater(remote.archiveEvent(''), throwsArgumentError);
      expect(adapter.sent, isEmpty);
    });

    test('a 400 is EventWriteConflictException', () async {
      // An archive of an event that is neither cancelled nor over. A repeat
      // archive is answered 200, not this.
      const notArchivable =
          'Only a cancelled event, or one whose dates have all passed, can be '
          'archived.';
      final remote = answering(
        _envelope(400, 'Bad Request', notArchivable),
        status: 400,
      );

      await expectLater(
        remote.archiveEvent('ev_1'),
        throwsA(
          isA<EventWriteConflictException>().having(
            (e) => e.apiMessage,
            'apiMessage',
            notArchivable,
          ),
        ),
      );
    });

    test('a 404 is EventRemoteNotFoundException', () async {
      final remote = answering(
        _envelope(404, 'Not Found', 'Event not found'),
        status: 404,
      );

      await expectLater(
        remote.archiveEvent('ev_1'),
        throwsA(isA<EventRemoteNotFoundException>()),
      );
    });

    test('a 403 envelope is EventWriteRefusedException', () async {
      final remote = answering(
        _envelope(403, 'Forbidden', 'You may not archive this event.'),
        status: 403,
      );

      await expectLater(
        remote.archiveEvent('ev_1'),
        throwsA(isA<EventWriteRefusedException>()),
      );
    });
  });

  group('occurrence writes (#506)', () {
    String occurrenceBody({
      String? cancelReason,
      String status = 'Confirmed',
    }) => jsonEncode({
      'message': 'Done',
      'occurrence': _occurrenceRow(
        id: 'o1',
        eventId: 'e1',
        status: status,
        cancelReason: cancelReason,
      ),
    });

    test('addOccurrence posts the draft in UTC with its sortOrder', () async {
      final remote = answering(occurrenceBody(), status: 201);

      final added = await remote.addOccurrence(
        'e1',
        EventOccurrenceDraft(
          label: 'Day 2',
          startDate: DateTime.parse('2026-11-07T20:00:00+02:00'),
          location: 'Hall',
        ),
        sortOrder: 3,
      );

      expect(adapter.sent.single.method, 'POST');
      expect(adapter.sent.single.path, '/api/events/e1/occurrences');
      expect(adapter.sent.single.body, {
        'label': 'Day 2',
        'startDate': '2026-11-07T18:00:00.000Z',
        'location': 'Hall',
        'sortOrder': 3,
      });
      expect(added.id, 'o1');
      expect(added.eventId, 'e1');
    });

    test(
      'updateOccurrence sends only what changed, and null to clear',
      () async {
        final remote = answering(occurrenceBody());

        await remote.updateOccurrence(
          'e1',
          'o1',
          OccurrenceUpdate(clearLocation: true),
        );

        expect(adapter.sent.single.method, 'PATCH');
        expect(adapter.sent.single.path, '/api/events/e1/occurrences/o1');
        expect(adapter.sent.single.body, {'location': null});
      },
    );

    test('updateOccurrence sends a trimmed value, and every clear', () async {
      final remote = answering(occurrenceBody());

      await remote.updateOccurrence(
        'e1',
        'o1',
        OccurrenceUpdate(
          label: ' Day 3 ',
          startDate: DateTime.utc(2026, 11, 9, 18),
          clearEndDate: true,
          clearLocation: true,
        ),
      );
      await remote.updateOccurrence(
        'e1',
        'o1',
        OccurrenceUpdate(clearLabel: true, endDate: DateTime.utc(2026, 11, 9)),
      );

      expect(adapter.sent.first.body, {
        'label': 'Day 3',
        'startDate': '2026-11-09T18:00:00.000Z',
        'endDate': null,
        'location': null,
      });
      expect(adapter.sent.last.body, {
        'label': null,
        'endDate': '2026-11-09T00:00:00.000Z',
      });
    });

    test('updateOccurrence refuses an empty update before sending', () async {
      final remote = answering(occurrenceBody());

      await expectLater(
        remote.updateOccurrence('e1', 'o1', OccurrenceUpdate()),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });

    test('confirmOccurrence, declineOccurrence and cancelOccurrence post to '
        'their routes and take a 201', () async {
      final remote = answering(occurrenceBody(), status: 201);

      final confirmed = await remote.confirmOccurrence('e1', 'o1');
      expect(adapter.sent.last.method, 'POST');
      expect(adapter.sent.last.path, '/api/events/e1/occurrences/o1/confirm');
      expect(confirmed.id, 'o1');

      await remote.declineOccurrence('e1', 'o1');
      expect(adapter.sent.last.method, 'POST');
      expect(adapter.sent.last.path, '/api/events/e1/occurrences/o1/decline');

      await remote.cancelOccurrence('e1', 'o1');
      expect(adapter.sent.last.method, 'POST');
      expect(adapter.sent.last.path, '/api/events/e1/occurrences/o1/cancel');
      expect(adapter.sent, hasLength(3));
    });

    test('cancelOccurrence sends a trimmed reason, and none when it is '
        'blank', () async {
      final remote = answering(occurrenceBody(), status: 201);

      await remote.cancelOccurrence('e1', 'o1', reason: '  rain ');
      await remote.cancelOccurrence('e1', 'o1', reason: '   ');
      await remote.cancelOccurrence('e1', 'o1');

      expect(adapter.sent[0].body, {'reason': 'rain'});
      expect(adapter.sent[1].body, <String, dynamic>{});
      expect(adapter.sent[2].body, <String, dynamic>{});
    });

    test(
      'cancelOccurrence takes a reason of exactly 1000 characters',
      () async {
        final remote = answering(occurrenceBody(), status: 201);

        await remote.cancelOccurrence('e1', 'o1', reason: ' ${'a' * 1000} ');

        expect(adapter.sent.single.body, {'reason': 'a' * 1000});
      },
    );

    test('cancelOccurrence counts a reason in code points, as the server '
        'does', () async {
      // One emoji is two UTF-16 code units, and one character to the
      // server's MaxLength.
      final remote = answering(occurrenceBody(), status: 201);

      await remote.cancelOccurrence('e1', 'o1', reason: '🎲' * 1000);

      expect(adapter.sent.single.body, {'reason': '🎲' * 1000});
    });

    test('cancelOccurrence refuses a reason past 1000 characters before '
        'sending', () async {
      final remote = answering(occurrenceBody(), status: 201);

      await expectLater(
        remote.cancelOccurrence('e1', 'o1', reason: 'a' * 1001),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });

    test('removeOccurrence deletes and reads no body', () async {
      final remote = answering('not json');

      await remote.removeOccurrence('e1', 'o1');

      expect(adapter.sent.single.method, 'DELETE');
      expect(adapter.sent.single.path, '/api/events/e1/occurrences/o1');
      expect(adapter.sent.single.body, isNull);
    });

    test('encodes the ids into the path', () async {
      final remote = answering(occurrenceBody());

      await remote.confirmOccurrence('a/b', 'c d');

      expect(
        adapter.sent.single.path,
        '/api/events/a%2Fb/occurrences/c%20d/confirm',
      );
    });

    test('an enveloped 400 on a date write is a conflict', () async {
      final remote = answering(
        _envelope(400, 'Bad Request', 'Occurrence is already cancelled'),
        status: 400,
      );

      await expectLater(
        remote.cancelOccurrence('e1', 'o1'),
        throwsA(
          isA<EventWriteConflictException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having(
                (e) => e.apiMessage,
                'apiMessage',
                'Occurrence is already cancelled',
              ),
        ),
      );
    });

    test("the validation pipe's 400 stays permanent", () async {
      // Its envelope lists a message per value refused, where the service's
      // judgement of the row has one. The same request is refused again.
      final remote = answering(
        jsonEncode({
          'statusCode': 400,
          'message': ['sortOrder must not be less than 0'],
          'error': 'Bad Request',
        }),
        status: 400,
      );

      await expectLater(
        remote.addOccurrence('e1', const EventOccurrenceDraft(), sortOrder: 0),
        throwsA(
          isA<EventRemotePermanentException>().having(
            (e) => e.statusCode,
            'statusCode',
            400,
          ),
        ),
      );
    });

    test('a 400 without the envelope stays permanent', () async {
      final remote = answering('<html>Bad</html>', status: 400);

      await expectLater(
        remote.confirmOccurrence('e1', 'o1'),
        throwsA(
          isA<EventRemotePermanentException>().having(
            (e) => e.statusCode,
            'statusCode',
            400,
          ),
        ),
      );
    });

    test(
      'an enveloped 404 is not found, an enveloped 403 is refused',
      () async {
        await expectLater(
          answering(
            _envelope(404, 'Not Found', 'Occurrence not found'),
            status: 404,
          ).confirmOccurrence('e1', 'o1'),
          throwsA(isA<EventRemoteNotFoundException>()),
        );
        await expectLater(
          answering(
            _envelope(403, 'Forbidden', 'Not a host'),
            status: 403,
          ).confirmOccurrence('e1', 'o1'),
          throwsA(
            isA<EventWriteRefusedException>().having(
              (e) => e.apiMessage,
              'apiMessage',
              'Not a host',
            ),
          ),
        );
      },
    );

    test('a 2xx with no occurrence is permanent', () async {
      for (final body in [
        jsonEncode({'message': 'Done'}),
        jsonEncode({'message': 'Done', 'occurrence': 'nope'}),
      ]) {
        await expectLater(
          answering(body, status: 201).confirmOccurrence('e1', 'o1'),
          throwsA(
            isA<EventRemotePermanentException>().having(
              (e) => e.statusCode,
              'statusCode',
              201,
            ),
          ),
        );
      }
    });

    test("the occurrence's cancelReason is read", () async {
      final fetched = await answering(
        _detailBody(
          _eventRow(
            occurrences: [
              _occurrenceRow(
                status: 'Cancelled',
                cancelledAt: '2026-10-05T10:00:00.000Z',
                cancelReason: 'Venue flooded',
              ),
            ],
            attendees: [],
          ),
        ),
      ).fetchEvent('ev_1');
      expect(fetched.occurrences.single.cancelReason, 'Venue flooded');

      final cancelled = await answering(
        occurrenceBody(cancelReason: 'rain', status: 'Cancelled'),
        status: 201,
      ).cancelOccurrence('e1', 'o1', reason: 'rain');
      expect(cancelled.cancelReason, 'rain');
    });

    test('every method refuses an empty id before sending', () async {
      final remote = answering(occurrenceBody());
      const draft = EventOccurrenceDraft(label: 'x');
      final update = OccurrenceUpdate(clearLabel: true);
      final calls = <Future<Object?> Function()>[
        () => remote.addOccurrence('', draft, sortOrder: 0),
        () => remote.updateOccurrence('', 'o1', update),
        () => remote.updateOccurrence('e1', '', update),
        () => remote.confirmOccurrence('', 'o1'),
        () => remote.confirmOccurrence('e1', ''),
        () => remote.declineOccurrence('', 'o1'),
        () => remote.declineOccurrence('e1', ''),
        () => remote.cancelOccurrence('', 'o1'),
        () => remote.cancelOccurrence('e1', ''),
        () => remote.removeOccurrence('', 'o1'),
        () => remote.removeOccurrence('e1', ''),
      ];

      for (final (index, call) in calls.indexed) {
        await expectLater(call(), throwsArgumentError, reason: 'call $index');
      }
      expect(adapter.sent, isEmpty);
    });
  });

  group('availability (#507)', () {
    /// `POST .../availability`'s answer: the bare vote row, with no `eligible`
    /// mark.
    String voteBody({String response = 'Maybe'}) => jsonEncode({
      'message': 'Availability recorded',
      'vote': {
        'id': 'v1',
        'occurrenceId': 'o1',
        'attendeeId': 'a1',
        'response': response,
        'createdAt': '2026-10-05T09:00:00.000Z',
        'updatedAt': '2026-10-05T09:30:00.000Z',
      },
    });

    /// One date of the summary as the backend serializes it: the tallies it
    /// computed, and the fields the models leave out.
    Map<String, dynamic> summaryDate({
      String occurrenceId = 'o1',
      List<Map<String, dynamic>>? voters,
    }) => {
      'occurrenceId': occurrenceId,
      'label': 'Saturday Evening',
      'startDate': '2026-11-07T19:00:00.000Z',
      'endDate': '2026-11-07T23:00:00.000Z',
      'status': 'Proposed',
      'available': 2,
      'maybe': 1,
      'unavailable': 0,
      'totalVotes': 3,
      'pendingVotes': 1,
      'participationRate': 0.75,
      'voters':
          voters ??
          [
            {'attendeeId': 'a1', 'response': 'Available', 'eligible': true},
            {'attendeeId': 'a9', 'response': 'Maybe', 'eligible': false},
          ],
    };

    String summaryBody(List<Map<String, dynamic>> dates) => jsonEncode({
      'summary': {
        'attendees': {
          'total': 4,
          'registered': 4,
          'guests': 0,
          'byStatus': {
            'attending': 3,
            'invited': 1,
            'maybe': 0,
            'notAttending': 0,
          },
        },
        'eligibleVoters': 4,
        'occurrences': dates,
      },
    });

    test('submitAvailability posts the response and reads the vote', () async {
      final remote = answering(voteBody(), status: 201);

      final vote = await remote.submitAvailability(
        'e1',
        'o1',
        AvailabilityResponse.maybe,
      );

      expect(adapter.sent.single.method, 'POST');
      expect(
        adapter.sent.single.path,
        '/api/events/e1/occurrences/o1/availability',
      );
      expect(adapter.sent.single.body, {'response': 'Maybe'});
      expect(vote.id, 'v1');
      expect(vote.occurrenceId, 'o1');
      expect(vote.attendeeId, 'a1');
      expect(vote.response, AvailabilityResponse.maybe);
      expect(vote.createdAt, DateTime.utc(2026, 10, 5, 9));
      expect(vote.updatedAt, DateTime.utc(2026, 10, 5, 9, 30));
    });

    test('submitAvailability encodes the ids into the path', () async {
      final remote = answering(voteBody(), status: 201);

      await remote.submitAvailability(
        'a/b',
        'c d',
        AvailabilityResponse.available,
      );

      expect(
        adapter.sent.single.path,
        '/api/events/a%2Fb/occurrences/c%20d/availability',
      );
    });

    test('submitAvailability refuses unknown before sending', () async {
      final remote = answering(voteBody(), status: 201);

      await expectLater(
        remote.submitAvailability('e1', 'o1', AvailabilityResponse.unknown),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });

    test('submitAvailability refuses an empty id before sending', () async {
      final remote = answering(voteBody(), status: 201);

      await expectLater(
        remote.submitAvailability('', 'o1', AvailabilityResponse.maybe),
        throwsArgumentError,
      );
      await expectLater(
        remote.submitAvailability('e1', '', AvailabilityResponse.maybe),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });

    test("submitAvailability's enveloped 400 is a conflict", () async {
      final remote = answering(
        _envelope(400, 'Bad Request', 'Occurrence is not proposed'),
        status: 400,
      );

      await expectLater(
        remote.submitAvailability('e1', 'o1', AvailabilityResponse.maybe),
        throwsA(
          isA<EventWriteConflictException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having(
                (e) => e.apiMessage,
                'apiMessage',
                'Occurrence is not proposed',
              ),
        ),
      );
    });

    test("submitAvailability's enveloped 403 is refused and its 404 is not "
        'found', () async {
      await expectLater(
        answering(
          _envelope(403, 'Forbidden', 'Not on the roster'),
          status: 403,
        ).submitAvailability('e1', 'o1', AvailabilityResponse.maybe),
        throwsA(
          isA<EventWriteRefusedException>().having(
            (e) => e.apiMessage,
            'apiMessage',
            'Not on the roster',
          ),
        ),
      );
      await expectLater(
        answering(
          _envelope(404, 'Not Found', 'Occurrence not found'),
          status: 404,
        ).submitAvailability('e1', 'o1', AvailabilityResponse.maybe),
        throwsA(isA<EventRemoteNotFoundException>()),
      );
    });

    test('a vote answer with no vote is permanent', () async {
      for (final body in [
        jsonEncode({'message': 'Done'}),
        jsonEncode({'message': 'Done', 'vote': 'nope'}),
      ]) {
        await expectLater(
          answering(
            body,
            status: 201,
          ).submitAvailability('e1', 'o1', AvailabilityResponse.maybe),
          throwsA(
            isA<EventRemotePermanentException>().having(
              (e) => e.statusCode,
              'statusCode',
              201,
            ),
          ),
        );
      }
    });

    test(
      "fetchAvailabilitySummary reads each date's tallies and voters",
      () async {
        final remote = answering(summaryBody([summaryDate()]));

        final summary = await remote.fetchAvailabilitySummary('e1');

        expect(adapter.sent.single.method, 'GET');
        expect(
          adapter.sent.single.path,
          '/api/events/e1/occurrences/summary/availability',
        );
        final date = summary.of('o1')!;
        expect(summary.occurrences, [date]);
        expect(date.occurrenceId, 'o1');
        expect(date.available, 2);
        expect(date.maybe, 1);
        expect(date.unavailable, 0);
        expect(date.voters, const [
          AvailabilityVoter(
            attendeeId: 'a1',
            response: AvailabilityResponse.available,
            eligible: true,
          ),
          AvailabilityVoter(
            attendeeId: 'a9',
            response: AvailabilityResponse.maybe,
            eligible: false,
          ),
        ]);
        expect(summary.of('o2'), isNull);
      },
    );

    test('fetchAvailabilitySummary says whether the roster is visible, by '
        'whether the server counts anyone', () async {
      Future<bool> visibleWith(Map<String, dynamic>? attendees) async {
        final body = jsonDecode(summaryBody([])) as Map<String, dynamic>;
        (body['summary'] as Map<String, dynamic>)['attendees'] = attendees;
        final summary = await answering(jsonEncode(body))
            .fetchAvailabilitySummary('e1');
        return summary.rosterVisible;
      }

      expect(await visibleWith({'total': 2}), isTrue);
      expect(await visibleWith({'total': 0}), isFalse);
      expect(await visibleWith(null), isTrue);
    });

    test('fetchAvailabilitySummary keeps the order of the dates', () async {
      final remote = answering(
        summaryBody([
          summaryDate(occurrenceId: 'o2', voters: []),
          summaryDate(voters: []),
        ]),
      );

      final summary = await remote.fetchAvailabilitySummary('e1');

      expect(summary.occurrences.map((date) => date.occurrenceId), [
        'o2',
        'o1',
      ]);
      expect(summary.of('o1')!.voters, isEmpty);
    });

    test('fetchAvailabilitySummary maps a 403 to forbidden and a 404 to not '
        'found', () async {
      await expectLater(
        answering(
          _envelope(403, 'Forbidden', 'Not allowed'),
          status: 403,
        ).fetchAvailabilitySummary('e1'),
        throwsA(isA<EventRemoteForbiddenException>()),
      );
      await expectLater(
        answering(
          _envelope(404, 'Not Found', 'Event not found'),
          status: 404,
        ).fetchAvailabilitySummary('e1'),
        throwsA(isA<EventRemoteNotFoundException>()),
      );
    });

    test(
      'fetchAvailabilitySummary refuses an empty id before sending',
      () async {
        final remote = answering(summaryBody([]));

        await expectLater(
          remote.fetchAvailabilitySummary(''),
          throwsArgumentError,
        );
        expect(adapter.sent, isEmpty);
      },
    );

    test('a voter with an unknown response reads as unknown, not a '
        'failure', () async {
      final remote = answering(
        summaryBody([
          summaryDate(
            voters: [
              {'attendeeId': 'a1', 'response': 'Sometimes', 'eligible': true},
            ],
          ),
        ]),
      );

      final summary = await remote.fetchAvailabilitySummary('e1');

      expect(
        summary.of('o1')!.voters.single.response,
        AvailabilityResponse.unknown,
      );
    });

    test('a summary this client cannot read is permanent', () async {
      for (final body in [
        jsonEncode({'message': 'Done'}),
        jsonEncode({'summary': 'nope'}),
        // No list of dates, as opposed to an empty one.
        jsonEncode({
          'summary': {'eligibleVoters': 4},
        }),
        // A date with no tallies.
        summaryBody([
          {
            'occurrenceId': 'o1',
            'voters': [
              {'attendeeId': 'a1', 'response': 'Available', 'eligible': true},
            ],
          },
        ]),
        // A date with no list of voters.
        summaryBody([summaryDate()..remove('voters')]),
        // A voter with no eligibility mark.
        summaryBody([
          summaryDate(
            voters: [
              {'attendeeId': 'a1', 'response': 'Available'},
            ],
          ),
        ]),
      ]) {
        await expectLater(
          answering(body).fetchAvailabilitySummary('e1'),
          throwsA(
            isA<EventRemotePermanentException>().having(
              (e) => e.statusCode,
              'statusCode',
              200,
            ),
          ),
          reason: body,
        );
      }
    });
  });

  group('attendance (#667)', () {
    Map<String, dynamic> attendance({
      String status = 'Maybe',
      String? role = 'EventGuest',
    }) => {
      'attendeeId': 'a1',
      'status': status,
      'role': role,
      'rsvpDate': null,
    };

    const maybeGuest = EventAttendance(
      attendeeId: 'a1',
      status: EventParticipationStatus.maybe,
      role: EventRole.guest,
    );

    test("a list row's attendance is read", () async {
      final remote = answering(
        _listBody([_eventRow()..['attendance'] = attendance()]),
      );

      final page = await remote.fetchEvents();

      expect(page.items.single.attendance, maybeGuest);
    });

    test("a detail row's attendance is read", () async {
      final remote = answering(
        _detailBody(_eventRow(attendees: [])..['attendance'] = attendance()),
      );

      final snapshot = await remote.fetchEvent('ev_1');

      expect(snapshot.attendance, maybeGuest);
    });

    test('a null or missing attendance reads as null', () async {
      final remote = answering(
        _listBody([_eventRow()..['attendance'] = null, _eventRow(id: 'ev_2')]),
      );

      final page = await remote.fetchEvents();

      expect(page.items[0].attendance, isNull);
      expect(page.items[1].attendance, isNull);
    });

    test(
      'a null role reads as null, and an unknown status as unknown',
      () async {
        final remote = answering(
          _listBody([
            _eventRow()
              ..['attendance'] = attendance(status: 'Sideline', role: null),
          ]),
        );

        final read = (await remote.fetchEvents()).items.single.attendance!;

        expect(read.role, isNull);
        expect(read.status, EventParticipationStatus.unknown);
      },
    );

    test('a malformed attendance is a contract breach', () async {
      for (final bad in <Object>[
        'yes',
        {'status': 'Maybe', 'role': null, 'rsvpDate': null},
      ]) {
        final list = answering(_listBody([_eventRow()..['attendance'] = bad]));
        await expectLater(
          list.fetchEvents(),
          throwsA(isA<EventRemotePermanentException>()),
          reason: '$bad on the list',
        );

        final detail = answering(
          _detailBody(_eventRow(attendees: [])..['attendance'] = bad),
        );
        await expectLater(
          detail.fetchEvent('ev_1'),
          throwsA(isA<EventRemotePermanentException>()),
          reason: '$bad on the detail',
        );
      }
    });

    test('a wrong-typed role is a contract breach', () async {
      final bad = attendance()..['role'] = 5;

      final list = answering(_listBody([_eventRow()..['attendance'] = bad]));
      await expectLater(
        list.fetchEvents(),
        throwsA(isA<EventRemotePermanentException>()),
        reason: 'on the list',
      );

      final detail = answering(
        _detailBody(_eventRow(attendees: [])..['attendance'] = bad),
      );
      await expectLater(
        detail.fetchEvent('ev_1'),
        throwsA(isA<EventRemotePermanentException>()),
        reason: 'on the detail',
      );
    });
  });

  group('RSVP (#508)', () {
    /// `PATCH .../status`'s answer: the attendee with its `user` and `role`
    /// embedded, as a roster row has them.
    String rsvpBody({String status = 'NotAttending'}) => jsonEncode({
      'message': 'Attendee status updated',
      'attendee': _attendeeRow(
        id: 'a1',
        status: status,
        user: _userRow(),
        role: _roleRow('EventGuest'),
      ),
    });

    Future<void> sendDefault(EventRemoteDataSource remote) => remote
        .updateAttendeeStatus('e1', 'a1', EventParticipationStatus.attending);

    test('sends the status and leaves notes out when none is given', () async {
      final remote = answering(rsvpBody());

      final attendee = await remote.updateAttendeeStatus(
        'e1',
        'a1',
        EventParticipationStatus.notAttending,
      );

      expect(adapter.sent.single.method, 'PATCH');
      expect(adapter.sent.single.path, '/api/events/e1/attendees/a1/status');
      expect(adapter.sent.single.body, {'status': 'NotAttending'});
      expect(attendee.id, 'a1');
      expect(attendee.status, EventParticipationStatus.notAttending);
      expect(attendee.displayName, 'Ada');
      expect(attendee.role, EventRole.guest);
    });

    test('sends an empty note to clear it', () async {
      final remote = answering(rsvpBody(status: 'Maybe'));

      await remote.updateAttendeeStatus(
        'e1',
        'a1',
        EventParticipationStatus.maybe,
        notes: '',
      );

      expect(adapter.sent.single.body, {'status': 'Maybe', 'notes': ''});
    });

    test('sends a note as given', () async {
      final remote = answering(rsvpBody(status: 'Maybe'));

      await remote.updateAttendeeStatus(
        'e1',
        'a1',
        EventParticipationStatus.maybe,
        notes: 'Bringing snacks.',
      );

      expect(adapter.sent.single.body, {
        'status': 'Maybe',
        'notes': 'Bringing snacks.',
      });
    });

    test('percent-encodes both ids', () async {
      final remote = answering(rsvpBody());

      await remote.updateAttendeeStatus(
        'a/b',
        'c d',
        EventParticipationStatus.attending,
      );

      expect(
        adapter.sent.single.path,
        '/api/events/a%2Fb/attendees/c%20d/status',
      );
    });

    test('throws ArgumentError before the request for an empty id or an '
        'unknown status', () async {
      final remote = answering(rsvpBody());

      await expectLater(
        remote.updateAttendeeStatus('', 'a1', EventParticipationStatus.maybe),
        throwsArgumentError,
      );
      await expectLater(
        remote.updateAttendeeStatus('e1', '', EventParticipationStatus.maybe),
        throwsArgumentError,
      );
      await expectLater(
        remote.updateAttendeeStatus(
          'e1',
          'a1',
          EventParticipationStatus.unknown,
        ),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });

    test('maps 404, 403, 400 and a network failure', () async {
      await expectLater(
        sendDefault(
          answering(
            _envelope(404, 'Not Found', 'Attendee not found'),
            status: 404,
          ),
        ),
        throwsA(isA<EventRemoteNotFoundException>()),
      );
      await expectLater(
        sendDefault(
          answering(_envelope(403, 'Forbidden', 'Not your row'), status: 403),
        ),
        throwsA(isA<EventWriteRefusedException>()),
      );
      await expectLater(
        sendDefault(
          answering(
            _envelope(400, 'Bad Request', 'Event has ended'),
            status: 400,
          ),
        ),
        throwsA(
          isA<EventWriteConflictException>().having(
            (e) => e.apiMessage,
            'apiMessage',
            'Event has ended',
          ),
        ),
      );
      await expectLater(
        sendDefault(
          answering(
            jsonEncode({
              'statusCode': 400,
              'message': ['status must be one of the listed values'],
              'error': 'Bad Request',
            }),
            status: 400,
          ),
        ),
        throwsA(isA<EventRemotePermanentException>()),
      );
      await expectLater(
        sendDefault(
          EventRemoteDataSourceImpl(
            unreachableDio(DioExceptionType.connectionError),
          ),
        ),
        throwsA(isA<EventRemoteTransientException>()),
      );
    });

    test('throws on an answer with no attendee object', () async {
      for (final body in [
        jsonEncode({'message': 'Done'}),
        jsonEncode({'message': 'Done', 'attendee': 'nope'}),
      ]) {
        await expectLater(
          sendDefault(answering(body)),
          throwsA(
            isA<EventRemotePermanentException>().having(
              (e) => e.statusCode,
              'statusCode',
              200,
            ),
          ),
        );
      }
    });
  });

  group('add and remove an attendee (#510)', () {
    String attendeeBody(String message) => jsonEncode({
      'message': message,
      'attendee': _attendeeRow(
        id: 'a9',
        status: 'Invited',
        user: _userRow(),
        role: _roleRow('EventParticipant'),
      ),
    });

    Future<EventAttendee> add(EventRemoteDataSource remote) =>
        remote.addAttendee('e1', userId: 'u1', role: EventRole.participant);

    test("addAttendee posts the user and the role's wire name", () async {
      final remote = answering(attendeeBody('Attendee added'), status: 201);

      await add(remote);

      expect(adapter.sent.single.method, 'POST');
      expect(adapter.sent.single.path, '/api/events/e1/attendees');
      expect(adapter.sent.single.body, {
        'userId': 'u1',
        'role': 'EventParticipant',
      });
    });

    test("addAttendee maps the answer's attendee", () async {
      final remote = answering(attendeeBody('Attendee added'), status: 201);

      final attendee = await add(remote);

      expect(attendee.id, 'a9');
      expect(attendee.status, EventParticipationStatus.invited);
      expect(attendee.displayName, 'Ada');
      expect(attendee.role, EventRole.participant);
    });

    test('an add answered 409 is a conflict', () async {
      final remote = answering(
        _envelope(409, 'Conflict', 'Already an attendee'),
        status: 409,
      );

      await expectLater(
        add(remote),
        throwsA(
          isA<EventWriteConflictException>()
              .having((e) => e.apiMessage, 'apiMessage', 'Already an attendee')
              .having((e) => e.statusCode, 'statusCode', 409),
        ),
      );
    });

    test('an add answered retryable 409 is transient', () async {
      final remote = answering(_deadlock(), status: 409);

      await expectLater(
        add(remote),
        throwsA(isA<EventRemoteTransientException>()),
      );
    });

    test('an add answered 403 is refused', () async {
      final remote = answering(
        _envelope(403, 'Forbidden', 'Not allowed'),
        status: 403,
      );

      await expectLater(
        add(remote),
        throwsA(
          isA<EventWriteRefusedException>().having(
            (e) => e.apiMessage,
            'apiMessage',
            'Not allowed',
          ),
        ),
      );
    });

    test('an add answered 404 is not found', () async {
      final remote = answering(
        _envelope(404, 'Not Found', 'No such user'),
        status: 404,
      );

      await expectLater(
        add(remote),
        throwsA(isA<EventRemoteNotFoundException>()),
      );
    });

    test('addAttendee refuses the host and unknown roles', () async {
      final remote = answering(attendeeBody('Attendee added'), status: 201);

      for (final role in [EventRole.host, EventRole.unknown]) {
        await expectLater(
          remote.addAttendee('e1', userId: 'u1', role: role),
          throwsArgumentError,
        );
      }
      expect(adapter.sent, isEmpty);
    });

    test("removeAttendee deletes the attendee's path", () async {
      final remote = answering(attendeeBody('Attendee removed'));

      final attendee = await remote.removeAttendee('e1', 'a 9');

      expect(adapter.sent.single.method, 'DELETE');
      expect(adapter.sent.single.path, '/api/events/e1/attendees/a%209');
      expect(attendee.id, 'a9');
    });

    test('a remove answered 404 is not found', () async {
      final remote = answering(
        _envelope(404, 'Not Found', 'Attendee not found'),
        status: 404,
      );

      await expectLater(
        remote.removeAttendee('e1', 'a9'),
        throwsA(isA<EventRemoteNotFoundException>()),
      );
    });
  });

  group('offered games (#516)', () {
    late _PathAdapter pathAdapter;

    /// A data source whose transport answers each request from [answer].
    EventRemoteDataSource routed(
      Future<_Reply> Function(RequestOptions options) answer,
    ) {
      pathAdapter = _PathAdapter(answer);
      final dio = Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = pathAdapter;
      return EventRemoteDataSourceImpl(dio);
    }

    /// A 200 answering [games] as one pool page.
    Future<_Reply> rows(
      List<Map<String, dynamic>> games, {
      int page = 1,
      bool hasMore = false,
      int? totalPages,
    }) async => (
      body: _offeredGamesBody(
        games,
        page: page,
        hasMore: hasMore,
        totalPages: totalPages,
      ),
      status: 200,
    );

    /// The page a pool read asks for.
    int pageOf(RequestOptions options) =>
        options.queryParameters['page'] as int;

    const expected = OfferedGame(
      id: 'og_1',
      attendeeId: 'att_1',
      collectionId: 'col_1',
      platformGameId: 'pg_1',
      gameId: 'game_1',
      title: 'Brass: Birmingham',
      subtitle: 'Deluxe Edition',
      platformName: 'Tabletop',
      platformType: PlatformType.tabletop,
      thumbnail: 'https://cdn.example.com/brass.png',
      medium: GameMedium.physical,
      contentType: ContentType.baseGame,
      publishYear: 2018,
      minPlayers: 2,
      maxPlayers: 4,
      minPlayTime: 60,
      maxPlayTime: 120,
      suppliedNominations: 2,
      suppliedLineup: 1,
    );

    group('fetchGamesPool', () {
      test('the pool is one paged read of the event', () async {
        final remote = answering(_offeredGamesBody([_offeredRow()]));

        final pool = await remote.fetchGamesPool('e1');

        expect(adapter.sent.single.method, 'GET');
        expect(adapter.sent.single.path, '/api/events/e1/offered-games');
        expect(adapter.sent.single.query, {'page': 1, 'limit': 100});
        expect(pool, [expected]);
      });

      test('reads every page in order', () async {
        final queries = <Map<String, dynamic>>[];
        final remote = routed((options) {
          queries.add(Map.of(options.queryParameters));
          return pageOf(options) == 1
              ? rows(
                  [_offeredRow(), _offeredRow(id: 'og_2')],
                  hasMore: true,
                  totalPages: 2,
                )
              : rows([_offeredRow(id: 'og_3')], page: 2);
        });

        final pool = await remote.fetchGamesPool('e1');

        expect(pathAdapter.paths, [
          '/api/events/e1/offered-games',
          '/api/events/e1/offered-games',
        ]);
        expect(queries, [
          {'page': 1, 'limit': 100},
          {'page': 2, 'limit': 100},
        ]);
        expect(pool.map((game) => game.id), ['og_1', 'og_2', 'og_3']);
      });

      test('a row repeated across pages is kept once', () async {
        // A game offered mid-read shifts the offsets of the title order, so
        // page 2 can start with page 1's last row.
        final remote = routed(
          (options) => pageOf(options) == 1
              ? rows([_offeredRow(), _offeredRow(id: 'og_2')], hasMore: true)
              : rows(
                  [
                    _offeredRow(id: 'og_2', title: 'Brass: Lancashire'),
                    _offeredRow(id: 'og_3'),
                  ],
                  page: 2,
                ),
        );

        final pool = await remote.fetchGamesPool('e1');

        expect(pool.map((game) => game.id), ['og_1', 'og_2', 'og_3']);
        expect(pool[1].title, 'Brass: Birmingham');
      });

      test('a page past its own last page is permanent', () async {
        final remote = routed(
          (options) => rows(
            [_offeredRow(id: 'og_${pageOf(options)}')],
            page: pageOf(options),
            hasMore: true,
            totalPages: 1,
          ),
        );

        await expectLater(
          remote.fetchGamesPool('e1'),
          throwsA(isA<EventRemotePermanentException>()),
        );
        expect(pathAdapter.paths, hasLength(1));
      });

      test('a page that adds nothing new is permanent', () async {
        final remote = routed(
          (options) => rows(
            [_offeredRow()],
            page: pageOf(options),
            hasMore: true,
            totalPages: 5,
          ),
        );

        await expectLater(
          remote.fetchGamesPool('e1'),
          throwsA(isA<EventRemotePermanentException>()),
        );
        expect(pathAdapter.paths, hasLength(2));
      });

      test('narrows to the attendee ids given', () async {
        final remote = answering(_offeredGamesBody([_offeredRow()]));

        await remote.fetchGamesPool('e1', attendeeIds: ['a1', 'a2']);

        expect(adapter.sent.single.query, {
          'page': 1,
          'limit': 100,
          'attendeeIds': 'a1,a2',
        });
      });

      test('an empty list reads nothing', () async {
        final remote = answering(_offeredGamesBody([_offeredRow()]));

        final pool = await remote.fetchGamesPool('e1', attendeeIds: []);

        expect(pool, isEmpty);
        expect(adapter.sent, isEmpty);
      });

      test('more than 100 ids throws before any request', () async {
        final remote = answering(_offeredGamesBody([]));
        final ids = [for (var i = 0; i < 101; i++) 'a$i'];

        await expectLater(
          remote.fetchGamesPool('e1', attendeeIds: ids),
          throwsArgumentError,
        );
        expect(adapter.sent, isEmpty);

        // 100 is the server's cap, and goes out.
        await remote.fetchGamesPool('e1', attendeeIds: ids.sublist(1));
        expect(adapter.sent, hasLength(1));
      });

      test('a cancel stops the read', () async {
        final cancel = Completer<void>();
        // Page 1 is not answered while the read runs, so the read can end
        // only by cancelling the request that is out.
        final answered = Completer<void>();
        final remote = routed((options) async {
          if (!cancel.isCompleted) cancel.complete();
          await answered.future;
          return rows(
            [_offeredRow(id: 'og_${pageOf(options)}')],
            page: pageOf(options),
            hasMore: true,
            totalPages: 3,
          );
        });

        await expectLater(
          remote
              .fetchGamesPool('e1', cancelled: cancel.future)
              // Bounded, so a request the cancel doesn't reach fails here
              // rather than waiting out the test's own timeout.
              .timeout(const Duration(seconds: 2)),
          throwsA(isA<EventRemoteTransientException>()),
        );
        expect(pathAdapter.paths, hasLength(1));
        answered.complete();
      });

      test('a cancel as a page lands sends no later page', () async {
        final cancel = Completer<void>();
        final remote = routed((options) {
          if (!cancel.isCompleted) cancel.complete();
          return rows(
            [_offeredRow(id: 'og_${pageOf(options)}')],
            page: pageOf(options),
            hasMore: true,
            totalPages: 3,
          );
        });

        await expectLater(
          remote.fetchGamesPool('e1', cancelled: cancel.future),
          throwsA(isA<EventRemoteTransientException>()),
        );
        expect(pathAdapter.paths, hasLength(1));
      });

      test("reads the platform game's players before the game's", () async {
        final remote = routed(
          (_) => rows([
            _offeredRow(
              platformMinPlayers: 3,
              platformMaxPlayers: 5,
              platformMinPlayTime: 45,
              platformMaxPlayTime: 90,
            ),
            _offeredRow(id: 'og_2'),
            // One of the platform game's two is set, so its pair stands, as
            // a collection row's does (#715).
            _offeredRow(
              id: 'og_3',
              platformMinPlayers: 3,
              platformMaxPlayTime: 90,
            ),
          ]),
        );

        final pool = await remote.fetchGamesPool('e1');

        expect(
          [
            for (final game in pool)
              (
                game.minPlayers,
                game.maxPlayers,
                game.minPlayTime,
                game.maxPlayTime,
              ),
          ],
          [(3, 5, 45, 90), (2, 4, 60, 120), (3, null, null, 90)],
        );
      });

      test('supplies null stays null', () async {
        final remote = routed(
          (_) => rows([
            _offeredRow(supplies: {'nominations': null, 'lineup': null}),
            // None the viewer can see is a count, not null.
            _offeredRow(
              id: 'og_2',
              supplies: {'nominations': 0, 'lineup': null},
            ),
            _offeredRow(id: 'og_3')..remove('supplies'),
          ]),
        );

        final pool = await remote.fetchGamesPool('e1');

        expect(
          [
            for (final game in pool)
              (game.suppliedNominations, game.suppliedLineup),
          ],
          [(null, null), (0, null), (null, null)],
        );
      });

      test('an empty thumbnail and no medium are none', () async {
        final remote = routed(
          (_) => rows([_offeredRow(thumbnail: '', medium: null)]),
        );

        final pool = await remote.fetchGamesPool('e1');

        expect(pool.single.thumbnail, isNull);
        expect(pool.single.medium, isNull);
      });

      test("the platform game's picture comes before the game's", () async {
        // As a collection row's does (#709): each one's thumbnail, else its
        // full image, and an empty string is none.
        final remote = routed(
          (_) => rows([
            _offeredRow(platformThumbnail: 'https://cdn.example.com/pg.png'),
            _offeredRow(id: 'og_2', platformThumbnail: ''),
            _offeredRow(
              id: 'og_3',
              platformThumbnail: '',
              platformImage: 'https://cdn.example.com/pg-full.png',
            ),
            _offeredRow(
              id: 'og_4',
              thumbnail: '',
              image: 'https://cdn.example.com/brass-full.png',
            ),
          ]),
        );

        final pool = await remote.fetchGamesPool('e1');

        expect(pool.map((game) => game.thumbnail), [
          'https://cdn.example.com/pg.png',
          'https://cdn.example.com/brass.png',
          'https://cdn.example.com/pg-full.png',
          'https://cdn.example.com/brass-full.png',
        ]);
      });

      test('a medium this client does not know is none', () async {
        final remote = routed(
          (_) => rows([
            _offeredRow(id: 'og_new', medium: 'PrintAndPlay'),
            _offeredRow(id: 'og_known'),
          ]),
        );

        final pool = await remote.fetchGamesPool('e1');

        expect(pool.map((game) => game.id), ['og_new', 'og_known']);
        expect(pool.first.medium, isNull);
        expect(pool.first.title, 'Brass: Birmingham');
        expect(pool.last.medium, GameMedium.physical);
      });

      test('no content type or platform type is none, and one this client '
          'does not know is unknown', () async {
        final remote = routed(
          (_) => rows([
            _offeredRow(contentType: null, platformType: null),
            _offeredRow(
              id: 'og_2',
              contentType: 'Boxed',
              platformType: 'Hologram',
            ),
          ]),
        );

        final pool = await remote.fetchGamesPool('e1');

        expect(pool.first.contentType, isNull);
        expect(pool.first.platformType, isNull);
        expect(pool.last.contentType, ContentType.unknown);
        expect(pool.last.platformType, PlatformType.unknown);
      });

      test('an offered games list that is missing is permanent', () async {
        final remote = answering(
          jsonEncode({
            'other': <Object?>[],
            'pagination': _pagination(total: 0),
          }),
        );

        await expectLater(
          remote.fetchGamesPool('e1'),
          throwsA(isA<EventRemotePermanentException>()),
        );
      });

      test('a game whose collection is not an object is permanent', () async {
        final remote = answering(
          _offeredGamesBody([_offeredRow()..['collection'] = null]),
        );

        await expectLater(
          remote.fetchGamesPool('e1'),
          throwsA(isA<EventRemotePermanentException>()),
        );
      });

      test('a 403 is forbidden', () async {
        final remote = answering(
          _envelope(403, 'Forbidden', 'Not allowed'),
          status: 403,
        );

        await expectLater(
          remote.fetchGamesPool('e1'),
          throwsA(
            isA<EventRemoteForbiddenException>().having(
              (e) => e.statusCode,
              'statusCode',
              403,
            ),
          ),
        );
      });

      test('a 404 is not found: the event is gone', () async {
        final remote = answering(
          _envelope(404, 'Not Found', 'Event not found'),
          status: 404,
        );

        await expectLater(
          remote.fetchGamesPool('e1', attendeeIds: ['a1']),
          throwsA(
            isA<EventRemoteNotFoundException>().having(
              (e) => e.statusCode,
              'statusCode',
              404,
            ),
          ),
        );
        expect(adapter.sent.single.path, '/api/events/e1/offered-games');
      });
    });

    group('offerGame', () {
      Future<OfferedGame> offer(EventRemoteDataSource remote) =>
          remote.offerGame('e1', 'a 1', collectionId: 'col_1');

      test('offering sends the collection id and parses the entry', () async {
        final remote = answering(
          jsonEncode({
            'message': 'Game added',
            // The read's row, without the attendee.
            'entry': _offeredRow()..remove('attendee'),
          }),
          status: 201,
        );

        final game = await offer(remote);

        expect(adapter.sent.single.method, 'POST');
        expect(
          adapter.sent.single.path,
          '/api/events/e1/attendees/a%201/games',
        );
        expect(adapter.sent.single.body, {'collectionId': 'col_1'});
        expect(game, expected);
      });

      test('an offer whose entry is not an object is permanent', () async {
        final remote = answering(
          jsonEncode({'message': 'Game added', 'entry': 'og_1'}),
          status: 201,
        );

        await expectLater(
          offer(remote),
          throwsA(isA<EventRemotePermanentException>()),
        );
      });

      test('an offer answered 403 is refused', () async {
        final remote = answering(
          _envelope(403, 'Forbidden', 'Not your collection'),
          status: 403,
        );

        await expectLater(
          offer(remote),
          throwsA(
            isA<EventWriteRefusedException>().having(
              (e) => e.statusCode,
              'statusCode',
              403,
            ),
          ),
        );
      });

      test('an offer answered 404 is not found', () async {
        final remote = answering(
          _envelope(404, 'Not Found', 'No such collection entry'),
          status: 404,
        );

        await expectLater(
          offer(remote),
          throwsA(
            isA<EventRemoteNotFoundException>().having(
              (e) => e.statusCode,
              'statusCode',
              404,
            ),
          ),
        );
      });

      test('an offer answered 409 is a conflict', () async {
        final remote = answering(
          _envelope(409, 'Conflict', 'Already on the list'),
          status: 409,
        );

        await expectLater(
          offer(remote),
          throwsA(
            isA<EventWriteConflictException>().having(
              (e) => e.statusCode,
              'statusCode',
              409,
            ),
          ),
        );
      });

      test('an offer answered an enveloped 400 is a conflict', () async {
        final remote = answering(
          _envelope(400, 'Bad Request', 'Removed from the collection'),
          status: 400,
        );

        await expectLater(
          offer(remote),
          throwsA(
            isA<EventWriteConflictException>().having(
              (e) => e.statusCode,
              'statusCode',
              400,
            ),
          ),
        );
      });

      test("the validation pipe's 400 on an offer is permanent", () async {
        final remote = answering(
          jsonEncode({
            'statusCode': 400,
            'error': 'Bad Request',
            'message': ['collectionId must be a string'],
          }),
          status: 400,
        );

        await expectLater(
          offer(remote),
          throwsA(isA<EventRemotePermanentException>()),
        );
      });

      test('an offer answered retryable 409 is transient', () async {
        final remote = answering(_deadlock(), status: 409);

        await expectLater(
          offer(remote),
          throwsA(isA<EventRemoteTransientException>()),
        );
      });
    });

    group('takeBackGame', () {
      Future<void> takeBack(EventRemoteDataSource remote) =>
          remote.takeBackGame('e1', 'a1', 'og 1');

      test('taking back sends a DELETE and reads no body', () async {
        final remote = answering('not the body this client reads');

        await takeBack(remote);

        expect(adapter.sent.single.method, 'DELETE');
        expect(
          adapter.sent.single.path,
          '/api/events/e1/attendees/a1/games/og%201',
        );
      });

      test('a take-back answered 403 is refused', () async {
        final remote = answering(
          _envelope(403, 'Forbidden', 'Not allowed'),
          status: 403,
        );

        await expectLater(
          takeBack(remote),
          throwsA(
            isA<EventWriteRefusedException>().having(
              (e) => e.statusCode,
              'statusCode',
              403,
            ),
          ),
        );
      });

      test('a take-back answered 404 is not found', () async {
        final remote = answering(
          _envelope(404, 'Not Found', 'Game list entry not found'),
          status: 404,
        );

        await expectLater(
          takeBack(remote),
          throwsA(
            isA<EventRemoteNotFoundException>().having(
              (e) => e.statusCode,
              'statusCode',
              404,
            ),
          ),
        );
      });

      test('a take-back answered retryable 409 is transient', () async {
        // The take-back's route takes row locks, so it can deadlock; a
        // retryable 409 is not the conflict the bloc reads as "nominated,
        // or in the lineup".
        final remote = answering(_deadlock(), status: 409);

        await expectLater(
          takeBack(remote),
          throwsA(isA<EventRemoteTransientException>()),
        );
      });

      test('a take-back answered 409 is a conflict', () async {
        final remote = answering(
          _envelope(409, 'Conflict', 'The game is still supplied'),
          status: 409,
        );

        await expectLater(
          takeBack(remote),
          throwsA(
            isA<EventWriteConflictException>().having(
              (e) => e.statusCode,
              'statusCode',
              409,
            ),
          ),
        );
      });
    });

    test('an empty id is refused before anything is sent', () async {
      final remote = answering(_offeredGamesBody([]));

      await expectLater(
        remote.fetchGamesPool('', attendeeIds: ['a1']),
        throwsArgumentError,
      );
      await expectLater(
        remote.fetchGamesPool('e1', attendeeIds: ['a1', '']),
        throwsArgumentError,
      );
      await expectLater(
        remote.offerGame('e1', 'a1', collectionId: ''),
        throwsArgumentError,
      );
      await expectLater(
        remote.takeBackGame('e1', '', 'og_1'),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });
  });

  group('nominations (#517)', () {
    late _PathAdapter pathAdapter;

    EventRemoteDataSource routed(
      Future<_Reply> Function(RequestOptions options) answer,
    ) {
      pathAdapter = _PathAdapter(answer);
      final dio = Dio(BaseOptions(validateStatus: (_) => true))
        ..httpClientAdapter = pathAdapter;
      return EventRemoteDataSourceImpl(dio);
    }

    Future<_Reply> reply(String body, {int status = 200}) async =>
        (body: body, status: status);

    // A page that says there is more counts one page past itself, unless
    // [totalPages] says otherwise.
    String page(
      List<Map<String, dynamic>> rows, {
      required int page,
      required bool hasMore,
      int? totalPages,
    }) => jsonEncode({
      'nominations': rows,
      'pagination': _pagination(
        page: page,
        total: rows.length,
        totalPages: totalPages ?? (hasMore ? page + 1 : page),
        hasMore: hasMore,
      ),
    });

    String one(Map<String, dynamic> row, {bool message = false}) =>
        jsonEncode({if (message) 'message': 'done', 'nomination': row});

    group('fetchNominations', () {
      test('follows hasMore across pages', () async {
        final remote = routed((options) {
          final pageNumber = options.queryParameters['page'];
          return reply(
            pageNumber == 1
                ? page(
                    [_nominationRow(), _nominationRow(id: 'n2')],
                    page: 1,
                    hasMore: true,
                  )
                : page([_nominationRow(id: 'n3')], page: 2, hasMore: false),
          );
        });

        final rows = await remote.fetchNominations('e1');

        expect(rows.map((row) => row.id), ['n1', 'n2', 'n3']);
        expect(pathAdapter.paths, [
          '/api/events/e1/nominations',
          '/api/events/e1/nominations',
        ]);
      });

      test('keeps the first of a nomination a later page repeats', () async {
        // A nomination created mid-read shifts the offsets of a newest-first
        // list, so page 2 can start with page 1's last row.
        final remote = routed((options) {
          final pageNumber = options.queryParameters['page'];
          return reply(
            pageNumber == 1
                ? page(
                    [_nominationRow(), _nominationRow(id: 'n2')],
                    page: 1,
                    hasMore: true,
                  )
                : page(
                    [
                      _nominationRow(id: 'n2', status: 'Paused'),
                      _nominationRow(id: 'n3'),
                    ],
                    page: 2,
                    hasMore: false,
                  ),
          );
        });

        final rows = await remote.fetchNominations('e1');

        expect(rows.map((row) => row.id), ['n1', 'n2', 'n3']);
        expect(rows[1].status, NominationStatus.open);
      });

      test('more past the last page the server counted is a contract break, '
          'and no later page is sent', () async {
        var calls = 0;
        final remote = routed((options) {
          calls++;
          return reply(
            page(
              [_nominationRow(id: 'n$calls')],
              page: calls,
              hasMore: true,
              totalPages: 1,
            ),
          );
        });

        await expectLater(
          remote.fetchNominations('e1'),
          throwsA(isA<EventRemotePermanentException>()),
        );
        expect(calls, 1);
      });

      test('a page that says there is more but adds nothing new is a '
          'contract break, and no later page is sent', () async {
        var calls = 0;
        final remote = routed((options) {
          calls++;
          return reply(
            page(
              [_nominationRow()],
              page: calls,
              hasMore: true,
              totalPages: 5,
            ),
          );
        });

        await expectLater(
          remote.fetchNominations('e1'),
          throwsA(isA<EventRemotePermanentException>()),
        );
        expect(calls, 2);
      });

      test('asks for 100 a page, from page 1', () async {
        final queries = <Map<String, dynamic>>[];
        final remote = routed((options) {
          queries.add(Map.of(options.queryParameters));
          return reply(
            page(
              [_nominationRow()],
              page: queries.length,
              hasMore: queries.length == 1,
            ),
          );
        });

        await remote.fetchNominations('e1');

        expect(queries, [
          {'page': 1, 'limit': 100},
          {'page': 2, 'limit': 100},
        ]);
      });

      test('a failure on a later page fails the whole read', () async {
        var calls = 0;
        final remote = routed((options) {
          calls++;
          return options.queryParameters['page'] == 1
              ? reply(page([_nominationRow()], page: 1, hasMore: true))
              : reply(
                  _envelope(500, 'Internal Server Error', 'Oops'),
                  status: 500,
                );
        });

        await expectLater(
          remote.fetchNominations('e1'),
          throwsA(isA<EventRemoteTransientException>()),
        );
        expect(calls, 2);
      });

      test('maps a nomination whole', () async {
        final remote = routed(
          (_) => reply(
            page(
              [
                _nominationRow(
                  occurrenceId: 'occ_1',
                  status: 'Paused',
                  pausedFrom: 'Open',
                  votingDeadline: '2026-11-20T18:00:00.000Z',
                  votes: [
                    _voteRow(comment: 'Yes!'),
                    _voteRow(
                      id: 'v2',
                      attendeeId: 'att_2',
                      voteType: 'Against',
                      eligible: false,
                    ),
                  ],
                ),
                _nominationRow(id: 'n2', guest: true, thumbnail: ''),
              ],
              page: 1,
              hasMore: false,
            ),
          ),
        );

        final rows = await remote.fetchNominations('e1');

        expect(
          rows.first,
          EventNomination(
            id: 'n1',
            eventId: 'e1',
            occurrenceId: 'occ_1',
            platformGameId: 'pg_1',
            gameId: 'game_1',
            title: 'Brass: Birmingham',
            platformName: 'Tabletop',
            thumbnail: 'https://cdn.example.com/brass.png',
            status: NominationStatus.paused,
            pausedFrom: NominationStatus.open,
            votingDeadline: DateTime.utc(2026, 11, 20, 18),
            nominatedById: 'att_1',
            nominatedByUsername: 'ada',
            suppliedFromId: 'og_1',
            createdAt: DateTime.utc(2026, 11, 1, 10),
            votes: const [
              EventNominationVote(
                id: 'v1',
                attendeeId: 'att_1',
                voteType: VoteType.forGame,
                eligible: true,
                comment: 'Yes!',
              ),
              EventNominationVote(
                id: 'v2',
                attendeeId: 'att_2',
                voteType: VoteType.against,
                eligible: false,
              ),
            ],
          ),
        );
        expect(rows.last.nominatedByUsername, isNull);
        expect(rows.last.thumbnail, isNull);
        expect(rows.last.pausedFrom, isNull);
        expect(rows.last.votingDeadline, isNull);
        expect(rows.last.occurrenceId, isNull);
      });

      test('a vote without eligible is a contract break', () async {
        final remote = routed(
          (_) => reply(
            page(
              [
                _nominationRow(
                  votes: [_voteRow()..remove('eligible')],
                ),
              ],
              page: 1,
              hasMore: false,
            ),
          ),
        );

        await expectLater(
          remote.fetchNominations('e1'),
          throwsA(isA<EventRemotePermanentException>()),
        );
      });

      test('an enveloped 403 and 404 are forbidden and not found', () async {
        final forbidden = routed(
          (_) => reply(_envelope(403, 'Forbidden', 'No'), status: 403),
        );
        await expectLater(
          forbidden.fetchNominations('e1'),
          throwsA(isA<EventRemoteForbiddenException>()),
        );
        final gone = routed(
          (_) => reply(_envelope(404, 'Not Found', 'Gone'), status: 404),
        );
        await expectLater(
          gone.fetchNominations('e1'),
          throwsA(isA<EventRemoteNotFoundException>()),
        );
      });
    });

    group('fetchNomination', () {
      test('reads one nomination', () async {
        final remote = routed((_) => reply(one(_nominationRow(id: 'n 1'))));

        final nomination = await remote.fetchNomination('e1', 'n 1');

        expect(nomination.id, 'n 1');
        expect(pathAdapter.paths, ['/api/events/e1/nominations/n%201']);
      });
    });

    group('nominate', () {
      Future<EventNomination> nominate(EventRemoteDataSource remote) =>
          remote.nominate('e1', platformGameId: 'pg_1', suppliedFromId: 'og_1');

      test('sends no occurrenceId for the whole event', () async {
        final remote = answering(
          one(_nominationRow(), message: true),
          status: 201,
        );

        final nomination = await nominate(remote);

        expect(adapter.sent.single.method, 'POST');
        expect(adapter.sent.single.path, '/api/events/e1/nominations');
        expect(adapter.sent.single.body, {
          'platformGameId': 'pg_1',
          'suppliedFromId': 'og_1',
        });
        expect(nomination.id, 'n1');
      });

      test('sends the occurrenceId for one date', () async {
        final remote = answering(
          one(_nominationRow(occurrenceId: 'occ_1'), message: true),
          status: 201,
        );

        await remote.nominate(
          'e1',
          platformGameId: 'pg_1',
          suppliedFromId: 'og_1',
          occurrenceId: 'occ_1',
        );

        expect(adapter.sent.single.body, {
          'platformGameId': 'pg_1',
          'suppliedFromId': 'og_1',
          'occurrenceId': 'occ_1',
        });
      });

      test('409 is a conflict carrying its status and message', () async {
        final remote = answering(
          _envelope(409, 'Conflict', 'Supplier not attending'),
          status: 409,
        );

        await expectLater(
          nominate(remote),
          throwsA(
            isA<EventWriteConflictException>()
                .having((e) => e.statusCode, 'statusCode', 409)
                .having(
                  (e) => e.apiMessage,
                  'apiMessage',
                  'Supplier not attending',
                ),
          ),
        );
      });

      test('400 with one message is a conflict carrying its status', () async {
        final remote = answering(
          _envelope(400, 'Bad Request', 'Row does not match'),
          status: 400,
        );

        await expectLater(
          nominate(remote),
          throwsA(
            isA<EventWriteConflictException>()
                .having((e) => e.statusCode, 'statusCode', 400)
                .having(
                  (e) => e.apiMessage,
                  'apiMessage',
                  'Row does not match',
                ),
          ),
        );
      });

      test('403 is refused', () async {
        final remote = answering(
          _envelope(403, 'Forbidden', 'Host only'),
          status: 403,
        );

        await expectLater(
          nominate(remote),
          throwsA(
            isA<EventWriteRefusedException>().having(
              (e) => e.statusCode,
              'statusCode',
              403,
            ),
          ),
        );
      });

      test('404 is not found', () async {
        final remote = answering(
          _envelope(404, 'Not Found', 'Gone'),
          status: 404,
        );

        await expectLater(
          nominate(remote),
          throwsA(isA<EventRemoteNotFoundException>()),
        );
      });
    });

    group('castVote', () {
      test('sends For as voteType, with no comment when none', () async {
        final remote = answering(
          jsonEncode({'message': 'ok', 'vote': <String, dynamic>{}}),
        );

        await remote.castVote('e1', 'n1', voteType: VoteType.forGame);

        expect(adapter.sent.single.method, 'POST');
        expect(adapter.sent.single.path, '/api/events/e1/nominations/n1/votes');
        expect(adapter.sent.single.body, {'voteType': 'For'});
      });

      test('sends the comment', () async {
        final remote = answering(jsonEncode({'message': 'ok'}));

        await remote.castVote(
          'e1',
          'n1',
          voteType: VoteType.against,
          comment: 'Too long',
        );

        expect(adapter.sent.single.body, {
          'voteType': 'Against',
          'comment': 'Too long',
        });
      });

      test('of unknown throws before sending', () async {
        final remote = answering('{}');

        await expectLater(
          remote.castVote('e1', 'n1', voteType: VoteType.unknown),
          throwsArgumentError,
        );
        expect(adapter.sent, isEmpty);
      });

      test('400 is a conflict', () async {
        final remote = answering(
          _envelope(400, 'Bad Request', 'Not open'),
          status: 400,
        );

        await expectLater(
          remote.castVote('e1', 'n1', voteType: VoteType.forGame),
          throwsA(
            isA<EventWriteConflictException>()
                .having((e) => e.statusCode, 'statusCode', 400)
                .having((e) => e.apiMessage, 'apiMessage', 'Not open'),
          ),
        );
      });

      test('403 is refused and 404 is not found', () async {
        final refused = answering(
          _envelope(403, 'Forbidden', 'No'),
          status: 403,
        );
        await expectLater(
          refused.castVote('e1', 'n1', voteType: VoteType.forGame),
          throwsA(isA<EventWriteRefusedException>()),
        );
        final gone = answering(
          _envelope(404, 'Not Found', 'Gone'),
          status: 404,
        );
        await expectLater(
          gone.castVote('e1', 'n1', voteType: VoteType.forGame),
          throwsA(isA<EventRemoteNotFoundException>()),
        );
      });
    });

    group('withdrawNomination', () {
      test('maps the answer', () async {
        final remote = answering(
          one(_nominationRow(status: 'Withdrawn'), message: true),
        );

        final nomination = await remote.withdrawNomination('e1', 'n1');

        expect(adapter.sent.single.method, 'PATCH');
        expect(
          adapter.sent.single.path,
          '/api/events/e1/nominations/n1/withdraw',
        );
        expect(nomination.status, NominationStatus.withdrawn);
      });

      test('400 is a conflict', () async {
        final remote = answering(
          _envelope(400, 'Bad Request', 'Cannot withdraw'),
          status: 400,
        );

        await expectLater(
          remote.withdrawNomination('e1', 'n1'),
          throwsA(isA<EventWriteConflictException>()),
        );
      });
    });

    group('approveNomination and rejectNomination', () {
      test('approveNomination maps the answer', () async {
        final remote = answering(
          one(_nominationRow(status: 'Approved'), message: true),
        );

        final nomination = await remote.approveNomination('e1', 'n1');

        expect(adapter.sent.single.method, 'POST');
        expect(
          adapter.sent.single.path,
          '/api/events/e1/nominations/n1/approve',
        );
        expect(nomination.status, NominationStatus.approved);
      });

      test('rejectNomination posts to reject and maps the answer', () async {
        final remote = answering(
          one(_nominationRow(status: 'Rejected'), message: true),
        );

        final nomination = await remote.rejectNomination('e1', 'n1');

        expect(adapter.sent.single.method, 'POST');
        expect(
          adapter.sent.single.path,
          '/api/events/e1/nominations/n1/reject',
        );
        expect(nomination.status, NominationStatus.rejected);
      });

      test('400 is a conflict, 403 refused, 404 not found', () async {
        await expectLater(
          answering(
            _envelope(400, 'Bad Request', 'Not awaiting'),
            status: 400,
          ).approveNomination('e1', 'n1'),
          throwsA(isA<EventWriteConflictException>()),
        );
        await expectLater(
          answering(
            _envelope(403, 'Forbidden', 'No'),
            status: 403,
          ).rejectNomination('e1', 'n1'),
          throwsA(isA<EventWriteRefusedException>()),
        );
        await expectLater(
          answering(
            _envelope(404, 'Not Found', 'Gone'),
            status: 404,
          ).rejectNomination('e1', 'n1'),
          throwsA(isA<EventRemoteNotFoundException>()),
        );
      });
    });

    group('resolveNomination', () {
      String resolved({String status = 'Passed', Object? tally}) => jsonEncode({
        'message': 'done',
        'nomination': _nominationRow(status: status),
        'resolution': {
          'status': status,
          'tally':
              tally ??
              {
                'forCount': 5,
                'againstCount': 2,
                'interestedCount': 1,
                'totalVotes': 8,
              },
          'quorumMet': true,
          'thresholdMet': false,
          'eligibleVoterCount': 9,
        },
      });

      test('resolveNomination maps the resolution', () async {
        final remote = answering(resolved());

        final result = await remote.resolveNomination('e1', 'n1');

        expect(adapter.sent.single.method, 'POST');
        expect(
          adapter.sent.single.path,
          '/api/events/e1/nominations/n1/resolve',
        );
        expect(result.nomination.status, NominationStatus.passed);
        expect(
          result.resolution,
          const NominationResolution(
            status: NominationStatus.passed,
            forCount: 5,
            againstCount: 2,
            interestedCount: 1,
            totalVotes: 8,
            quorumMet: true,
            thresholdMet: false,
            eligibleVoterCount: 9,
          ),
        );
      });

      test('an unknown resolution status degrades to unknown', () async {
        final remote = answering(resolved(status: 'Mystery'));

        final result = await remote.resolveNomination('e1', 'n1');

        expect(result.resolution.status, NominationStatus.unknown);
      });

      test('a resolution without a tally is a format failure', () async {
        final remote = answering(
          jsonEncode({
            'nomination': _nominationRow(),
            'resolution': {'status': 'Passed'},
          }),
        );

        await expectLater(
          remote.resolveNomination('e1', 'n1'),
          throwsA(isA<EventRemoteException>()),
        );
      });

      test('resolve 400 is a conflict', () async {
        final remote = answering(
          _envelope(400, 'Bad Request', 'Cannot resolve'),
          status: 400,
        );

        await expectLater(
          remote.resolveNomination('e1', 'n1'),
          throwsA(
            isA<EventWriteConflictException>().having(
              (e) => e.apiMessage,
              'apiMessage',
              'Cannot resolve',
            ),
          ),
        );
      });
    });

    test('an empty id throws for approve, reject and resolve', () async {
      final remote = answering('{}');

      for (final call in [
        remote.approveNomination,
        remote.rejectNomination,
        remote.resolveNomination,
      ]) {
        await expectLater(call('', 'n1'), throwsArgumentError);
        await expectLater(call('e1', ''), throwsArgumentError);
      }
      expect(adapter.sent, isEmpty);
    });

    test('an empty id throws ArgumentError', () async {
      final remote = answering('{}');

      await expectLater(remote.fetchNominations(''), throwsArgumentError);
      await expectLater(
        remote.fetchNomination('e1', ''),
        throwsArgumentError,
      );
      await expectLater(
        remote.nominate('e1', platformGameId: '', suppliedFromId: 'og_1'),
        throwsArgumentError,
      );
      await expectLater(
        remote.nominate('e1', platformGameId: 'pg_1', suppliedFromId: ''),
        throwsArgumentError,
      );
      await expectLater(
        remote.castVote('', 'n1', voteType: VoteType.forGame),
        throwsArgumentError,
      );
      await expectLater(
        remote.castVote('e1', '', voteType: VoteType.forGame),
        throwsArgumentError,
      );
      await expectLater(
        remote.withdrawNomination('e1', ''),
        throwsArgumentError,
      );
      expect(adapter.sent, isEmpty);
    });
  });

  group('classification', () {
    test('any 2xx is a success, not only 200', () async {
      // Every event write answers 201, whatever the API's description says,
      // so a check narrowed to 200 would fail the create (#499) and the writes
      // #527 adds. The create's own tests pin it there; this pins it on a read.
      final remote = answering(
        _detailBody(_eventRow(attendees: [])),
        status: 201,
      );

      final snapshot = await remote.fetchEvent('ev_1');

      expect(snapshot.event.id, 'ev_1');
    });

    test('a 403 from the API is forbidden', () async {
      final remote = answering(
        _envelope(403, 'Forbidden', 'You are not allowed to do that.'),
        status: 403,
      );

      await expectLater(
        remote.fetchEvents(limit: 1),
        throwsA(
          isA<EventRemoteForbiddenException>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
      await expectLater(
        remote.fetchEvent('ev_1'),
        throwsA(isA<EventRemoteForbiddenException>()),
      );
    });

    test('a 403 without the envelope is transient', () async {
      // A proxy or WAF answered, so it says nothing about the caller's role.
      final remote = answering(
        '<html>Blocked by corporate proxy</html>',
        status: 403,
      );

      await expectLater(
        remote.fetchEvent('ev_1'),
        throwsA(isA<EventRemoteTransientException>()),
      );
      await expectLater(
        remote.fetchEvents(limit: 1),
        throwsA(isA<EventRemoteTransientException>()),
      );
    });

    test('a 409 marked retryable is transient', () async {
      final remote = answering(_deadlock(), status: 409);

      await expectLater(
        remote.fetchEvent('ev_1'),
        throwsA(
          isA<EventRemoteTransientException>().having(
            (e) => e.statusCode,
            'statusCode',
            409,
          ),
        ),
      );
    });

    test('any other 409 is permanent', () async {
      final remote = answering(
        _envelope(409, 'Conflict', 'Something else collided.'),
        status: 409,
      );

      await expectLater(
        remote.fetchEvent('ev_1'),
        throwsA(
          isA<EventRemotePermanentException>().having(
            (e) => e.statusCode,
            'statusCode',
            409,
          ),
        ),
      );
    });

    test('a 400 from the API is permanent', () async {
      final remote = answering(
        _envelope(400, 'Bad Request', 'limit must not be greater than 100'),
        status: 400,
      );

      await expectLater(
        remote.fetchEvents(limit: 1),
        throwsA(isA<EventRemotePermanentException>()),
      );
    });

    test('a 401, 408 and 429 are transient', () async {
      for (final status in [401, 408, 429]) {
        final remote = answering(
          _envelope(status, 'Error', 'Try again.'),
          status: status,
        );

        await expectLater(
          remote.fetchEvents(limit: 1),
          throwsA(
            isA<EventRemoteTransientException>().having(
              (e) => e.statusCode,
              'statusCode',
              status,
            ),
          ),
          reason: 'status $status',
        );
      }
    });

    test('a 407 from a proxy is transient', () async {
      final remote = answering('', status: 407);

      await expectLater(
        remote.fetchEvent('ev_1'),
        throwsA(isA<EventRemoteTransientException>()),
      );
    });

    test('a 500 is transient', () async {
      final remote = answering(
        _envelope(500, 'Internal Server Error', 'Internal server error'),
        status: 500,
      );

      await expectLater(
        remote.fetchEvents(limit: 1),
        throwsA(
          isA<EventRemoteTransientException>().having(
            (e) => e.statusCode,
            'statusCode',
            500,
          ),
        ),
      );
    });

    test('a redirect carries no rejection, so it is transient', () async {
      final remote = answering('', status: 302);

      await expectLater(
        remote.fetchEvent('ev_1'),
        throwsA(isA<EventRemoteTransientException>()),
      );
    });

    test('an HTML 200 is permanent, with its status', () async {
      final remote = answering('<html>Sign in to the hotel wifi</html>');

      await expectLater(
        remote.fetchEvents(),
        throwsA(
          isA<EventRemotePermanentException>().having(
            (e) => e.statusCode,
            'statusCode',
            200,
          ),
        ),
      );
    });

    test('an empty 200 is permanent', () async {
      final remote = answering('');

      await expectLater(
        remote.fetchEvent('ev_1'),
        throwsA(isA<EventRemotePermanentException>()),
      );
    });

    test('an unreachable server is transient', () async {
      final remote = EventRemoteDataSourceImpl(
        unreachableDio(DioExceptionType.connectionError),
      );

      await expectLater(
        remote.fetchEvents(limit: 1),
        throwsA(isA<EventRemoteTransientException>()),
      );
      await expectLater(
        remote.fetchEvent('ev_1'),
        throwsA(isA<EventRemoteTransientException>()),
      );
    });
  });
}
