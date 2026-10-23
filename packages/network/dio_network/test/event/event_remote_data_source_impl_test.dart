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
}) => {
  'id': id,
  'householdId': householdId,
  'createdById': 'user_ada',
  'cancelledById': null,
  'cancelReason': null,
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
  int page = 1,
  int limit = 100,
  required int total,
  bool hasMore = false,
}) => {
  'page': page,
  'limit': limit,
  'total': total,
  'totalPages': 1,
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
          _eventRow(attendees: [_attendeeRow(user: _userRow(), role: null)]),
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

  group('classification', () {
    test('any 2xx is a success, not only 200', () async {
      // Every event write answers 201, whatever the API's description says,
      // so a check narrowed to 200 would fail the writes #499 and #527 add
      // here. Pinned on a read until then.
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
