import 'package:models/domain.dart';

/// The instant every builder stamps a row with unless a test says otherwise.
final kItemInstant = DateTime.utc(2026, 9, 1, 12);

/// One event on the user's list, with whatever a test needs set and the rest
/// at plausible defaults: a Fixed event with no dates, no venue, no
/// household, and no known attendance.
EventListItem item(
  String id, {
  String title = 'Game night',
  EventSchedulingMode schedulingMode = EventSchedulingMode.fixed,
  DateTime? createdAt,
  String? location,
  String? householdId,
  List<EventOccurrence> occurrences = const [],
  EventAttendee? attendance,
}) {
  final at = createdAt ?? kItemInstant;
  return EventListItem(
    event: Event(
      id: id,
      title: title,
      createdById: 'user-host',
      householdId: householdId,
      location: location,
      type: EventType.casualGathering,
      reach: Reach.friends,
      status: EventStatus.planning,
      schedulingMode: schedulingMode,
      createdAt: at,
      updatedAt: at,
    ),
    occurrences: occurrences,
    attendance: attendance,
  );
}

/// A confirmed date starting at [start]. Vary its status with `copyWith`.
EventOccurrence confirmed(
  String id,
  DateTime start, {
  DateTime? end,
  String? location,
  int sortOrder = 0,
}) => EventOccurrence(
  id: id,
  eventId: 'e',
  startDate: start,
  endDate: end,
  location: location,
  status: OccurrenceStatus.confirmed,
  sortOrder: sortOrder,
  createdAt: kItemInstant,
  updatedAt: kItemInstant,
);

/// The current user's row on an event's roster, answered [status].
EventAttendee attendance(EventParticipationStatus status) => EventAttendee(
  id: 'att-me',
  eventId: 'e',
  userId: 'user-me',
  status: status,
  createdAt: kItemInstant,
  updatedAt: kItemInstant,
);
