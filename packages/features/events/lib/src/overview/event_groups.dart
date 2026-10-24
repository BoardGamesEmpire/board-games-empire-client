import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// The overview's groups (#497), in the order it shows them. Each one's
/// [name] is the route segment of its own page.
enum EventGroup { upcoming, planning, past }

/// One event as the overview shows it (#497): the group it falls in, the
/// date it shows, and the rest of its row.
final class EventRow extends Equatable {
  const EventRow({
    required this.event,
    required this.group,
    this.date,
    this.dateBeingChosen = false,
    this.venue,
    this.householdName,
    this.rsvp,
  });

  final Event event;
  final EventGroup group;

  /// The confirmed date the row shows: the soonest that hasn't ended for an
  /// upcoming event, the latest for a past one. Null in planning, where the
  /// event has none.
  final EventOccurrence? date;

  /// Whether a planning row's date is being chosen, which is true of a Poll
  /// event only. Any other event with no date has no date yet: nobody is
  /// choosing one. Always false outside planning.
  final bool dateBeingChosen;

  /// The shown date's location, else the event's. Null when neither has one
  /// that isn't blank.
  final String? venue;

  /// The name of the event's household, when the household is cached. Null
  /// for an event outside any household, and for one whose household this
  /// user doesn't belong to.
  final String? householdName;

  /// The user's answer, when their attendee row is cached. Null when it
  /// isn't, which is not known rather than unanswered, and for an answer
  /// this client can't read.
  final EventParticipationStatus? rsvp;

  @override
  List<Object?> get props => [
    event,
    group,
    date,
    dateBeingChosen,
    venue,
    householdName,
    rsvp,
  ];
}

/// The user's events, grouped (#497). A group with no events is empty, not
/// absent.
final class EventGroups extends Equatable {
  const EventGroups({
    this.upcoming = const [],
    this.planning = const [],
    this.past = const [],
  });

  /// Soonest first.
  final List<EventRow> upcoming;

  /// Newest created first, the list's own order.
  final List<EventRow> planning;

  /// Most recent first.
  final List<EventRow> past;

  /// The rows of [group].
  List<EventRow> of(EventGroup group) => switch (group) {
    EventGroup.upcoming => upcoming,
    EventGroup.planning => planning,
    EventGroup.past => past,
  };

  /// Whether every group is empty.
  bool get isEmpty => upcoming.isEmpty && planning.isEmpty && past.isEmpty;

  @override
  List<Object?> get props => [upcoming, planning, past];
}

/// Groups [items], the list's events in its order, against [now] (#497).
///
/// Only a confirmed date with a start counts. An event with one that hasn't
/// ended is upcoming; one whose every such date has ended is past; one with
/// none is planning. A date has ended once its end, or its start when it has
/// no end, is before [now], so a date ending at [now] is still upcoming.
///
/// The dates decide, not `Event.status`. A Poll event is created `planning`
/// and nothing on the server changes its status once a date is confirmed
/// (backend#795), so the status would leave it in planning.
///
/// [now] is a parameter because the groups move as time passes without any
/// write to the cache: an event that ends while the overview is open moves to
/// past at the next grouping. Instants compare as instants, whatever zone
/// they were read in.
///
/// [householdNames] maps a household's id to its name, for the households
/// the user belongs to.
EventGroups groupEvents(
  List<EventListItem> items, {
  required DateTime now,
  Map<String, String> householdNames = const {},
}) {
  final upcoming = <(_Date, EventRow)>[];
  final planning = <EventRow>[];
  final past = <(_Date, EventRow)>[];

  for (final item in items) {
    final event = item.event;
    EventRow row(EventGroup group, {EventOccurrence? date}) => EventRow(
      event: event,
      group: group,
      date: date,
      dateBeingChosen:
          group == EventGroup.planning &&
          event.schedulingMode == EventSchedulingMode.poll,
      venue: _venue(date, event),
      householdName: householdNames[event.householdId],
      rsvp: switch (item.attendance?.status) {
        null || EventParticipationStatus.unknown => null,
        final status => status,
      },
    );

    final dates = [
      for (final o in item.occurrences)
        if (o.startDate case final start?
            when o.status == OccurrenceStatus.confirmed)
          (occurrence: o, start: start, end: o.endDate ?? start),
    ];
    if (dates.isEmpty) {
      planning.add(row(EventGroup.planning));
      continue;
    }

    final notEnded = dates.where((d) => !d.end.isBefore(now)).toList();
    if (notEnded.isNotEmpty) {
      final soonest = notEnded.reduce(
        (a, b) => _soonestFirst(a, b) <= 0 ? a : b,
      );
      upcoming.add((
        soonest,
        row(EventGroup.upcoming, date: soonest.occurrence),
      ));
    } else {
      final latest = dates.reduce((a, b) => _latestFirst(a, b) <= 0 ? a : b);
      past.add((latest, row(EventGroup.past, date: latest.occurrence)));
    }
  }

  // Ties between events go to the event id, so the order never depends on
  // the order the cache happened to return.
  upcoming.sort((a, b) {
    final byStart = a.$1.start.compareTo(b.$1.start);
    return byStart != 0 ? byStart : a.$2.event.id.compareTo(b.$2.event.id);
  });
  past.sort((a, b) {
    final byStart = b.$1.start.compareTo(a.$1.start);
    return byStart != 0 ? byStart : a.$2.event.id.compareTo(b.$2.event.id);
  });

  return EventGroups(
    upcoming: [for (final (_, row) in upcoming) row],
    planning: planning,
    past: [for (final (_, row) in past) row],
  );
}

/// A date that counts: a confirmed occurrence, its start, and when it is
/// over, which is its end, or its start when it has none.
typedef _Date = ({EventOccurrence occurrence, DateTime start, DateTime end});

/// Orders dates by start, earliest first. Two that start at the same instant
/// keep the server's order, sortOrder then id, as [_latestFirst]'s do.
int _soonestFirst(_Date a, _Date b) {
  final byStart = a.start.compareTo(b.start);
  return byStart != 0 ? byStart : _serverOrder(a.occurrence, b.occurrence);
}

/// Orders dates by start, latest first, ties as [_soonestFirst] breaks them.
int _latestFirst(_Date a, _Date b) {
  final byStart = b.start.compareTo(a.start);
  return byStart != 0 ? byStart : _serverOrder(a.occurrence, b.occurrence);
}

int _serverOrder(EventOccurrence a, EventOccurrence b) {
  final bySortOrder = a.sortOrder.compareTo(b.sortOrder);
  return bySortOrder != 0 ? bySortOrder : a.id.compareTo(b.id);
}

/// The first of [date]'s location and [event]'s that isn't blank.
String? _venue(EventOccurrence? date, Event event) {
  for (final place in [date?.location, event.location]) {
    if (place != null && place.trim().isNotEmpty) return place;
  }
  return null;
}
