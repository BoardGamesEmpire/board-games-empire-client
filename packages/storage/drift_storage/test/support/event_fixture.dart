import 'package:models/domain.dart';

/// The event cache's model fixtures (#496), one copy for the whole package,
/// as `platform_game_fixture.dart` is for games: a field the models gain is a
/// single edit here.
///
/// Every builder sets every field, each to its own value, so a round trip
/// through the cache catches a column read into the wrong field. That makes
/// some of them implausible together, such as an occurrence both confirmed
/// and cancelled, which the cache neither knows nor checks. A builder takes
/// as parameters only what the suites vary; anything else varies by
/// `copyWith`.

/// The instant the fixtures are stamped with unless a suite says otherwise:
/// a whole millisecond, as the server sends.
final kFixtureEventInstant = DateTime.utc(2026, 10, 1, 12, 0, 0, 123);

/// The event [id], created at [createdAt].
Event testEvent(String id, {DateTime? createdAt, String title = 'Game night'}) {
  final at = createdAt ?? kFixtureEventInstant;
  return Event(
    id: id,
    title: title,
    createdById: 'user-host',
    householdId: 'household-1',
    description: 'Bring snacks.',
    image: 'https://example.com/events/$id.png',
    location: 'Kitchen table',
    url: 'https://example.com/events/$id',
    type: EventType.strategyNight,
    reach: Reach.friendsOfFriends,
    status: EventStatus.ongoing,
    schedulingMode: EventSchedulingMode.multiDay,
    createdAt: at,
    updatedAt: at.add(const Duration(minutes: 5)),
  );
}

/// A dated occurrence of [eventId].
EventOccurrence testOccurrence(
  String id, {
  String eventId = 'e-1',
  int sortOrder = 0,
}) => EventOccurrence(
  id: id,
  eventId: eventId,
  label: 'Day ${sortOrder + 1}',
  startDate: kFixtureEventInstant.add(const Duration(days: 7)),
  endDate: kFixtureEventInstant.add(const Duration(days: 7, hours: 4)),
  location: 'Back room',
  status: OccurrenceStatus.confirmed,
  sortOrder: sortOrder,
  confirmedAt: kFixtureEventInstant.add(const Duration(days: 1)),
  declinedAt: kFixtureEventInstant.add(const Duration(days: 2)),
  cancelledAt: kFixtureEventInstant.add(const Duration(days: 3)),
  createdAt: kFixtureEventInstant,
  updatedAt: kFixtureEventInstant.add(const Duration(hours: 2)),
);

/// [userId]'s place on the roster of [eventId], as an account holder's row.
EventAttendee testAttendee(
  String id, {
  required String userId,
  String eventId = 'e-1',
  DateTime? createdAt,
}) {
  final at = createdAt ?? kFixtureEventInstant;
  return EventAttendee(
    id: id,
    eventId: eventId,
    userId: userId,
    username: 'name-$userId',
    displayName: 'Display $userId',
    avatarUrl: 'https://example.com/avatars/$userId.png',
    notes: 'Bringing Catan.',
    status: EventParticipationStatus.attending,
    role: EventRole.participant,
    rsvpDate: at.add(const Duration(hours: 1)),
    createdAt: at,
    updatedAt: at.add(const Duration(hours: 2)),
  );
}

/// A guest on the roster of [eventId]: no account, so only a name.
EventAttendee testGuest(
  String id, {
  String eventId = 'e-1',
  String name = 'Grandma',
}) => EventAttendee(
  id: id,
  eventId: eventId,
  guestName: name,
  notes: 'Added by the host.',
  status: EventParticipationStatus.invited,
  role: EventRole.guest,
  createdAt: kFixtureEventInstant,
  updatedAt: kFixtureEventInstant.add(const Duration(hours: 3)),
);

/// The policy of [eventId].
EventPolicy testPolicy({String id = 'pol-1', String eventId = 'e-1'}) =>
    EventPolicy(
      id: id,
      eventId: eventId,
      allowMemberInvites: true,
      allowGuestInvites: false,
      maxAttendees: 8,
      restrictToGameCategories: true,
      requireHostApprovalToJoin: false,
      allowSpectators: true,
      maxTotalParticipants: 12,
      strictCapacity: false,
      gameAdditionMode: GameAdditionMode.hostApproval,
      restrictToAttendeePool: true,
      fillerMaxPlayTime: 30,
      voteThresholdType: VoteThresholdType.supermajority,
      voteThresholdValue: 66,
      voteQuorumType: VoteQuorumType.percentOfAttendees,
      voteQuorumValue: 50,
      voteEligibility: VoteEligibility.poolParticipants,
      interestedWeight: InterestedWeight.asAgainst,
      votingWindowHours: 48,
      createdAt: kFixtureEventInstant,
      updatedAt: kFixtureEventInstant.add(const Duration(hours: 4)),
    );

/// The event [id] as one read returned it: with one dated occurrence unless
/// [occurrences] says otherwise, [policy] when given, and [attendees] as
/// given. Leave [attendees] out for the list's snapshot, which carries no
/// roster.
EventSnapshot testSnapshot(
  String id, {
  DateTime? createdAt,
  String title = 'Game night',
  List<EventOccurrence>? occurrences,
  EventPolicy? policy,
  List<EventAttendee>? attendees,
}) => EventSnapshot(
  event: testEvent(id, createdAt: createdAt, title: title),
  occurrences: occurrences ?? [testOccurrence('$id-o1', eventId: id)],
  policy: policy,
  attendees: attendees,
);
