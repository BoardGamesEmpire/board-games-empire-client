import 'package:equatable/equatable.dart';
import 'package:events/src/detail/event_status_now.dart';
import 'package:models/domain.dart';

/// The overview's groups (#497), in the order it shows them. Each one's
/// [name] is the route segment of its own page.
///
/// [archived] holds the events the host has archived (#502), whatever their
/// dates; no other group does.
enum EventGroup { upcoming, planning, past, archived }

/// One event as the overview shows it (#497): the group it falls in, the
/// date it shows, and the rest of its row.
final class EventRow extends Equatable {
  const EventRow({
    required this.event,
    required this.group,
    this.date,
    this.dateBeingChosen = false,
    this.cancelled = false,
    this.venue,
    this.householdName,
    this.rsvp,
  });

  final Event event;
  final EventGroup group;

  /// The date the row shows, out of the dates its event counts: the soonest
  /// that hasn't ended for an upcoming event, the latest for a past or
  /// archived one. Those are its confirmed dates, or for a cancelled event the
  /// dates its cancel took away, so a cancelled row shows a cancelled date
  /// (#502). Null in planning, where the event has none, and for an archived
  /// event with none.
  final EventOccurrence? date;

  /// Whether a planning row's date is being chosen, which is true of a Poll
  /// event only, and not of a cancelled one: its cancel declined every
  /// proposed date. Any other event with no date has no date yet: nobody is
  /// choosing one. Always false outside planning.
  final bool dateBeingChosen;

  /// Whether the event is cancelled (#502), in any group, or was cancelled
  /// before it was archived, as its detail says too. A cancelled event keeps
  /// the place it had, and the row says so.
  final bool cancelled;

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
    cancelled,
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
    this.archived = const [],
  });

  /// Soonest first.
  final List<EventRow> upcoming;

  /// Newest created first, the list's own order.
  final List<EventRow> planning;

  /// Most recent first.
  final List<EventRow> past;

  /// Most recent date first, then the events with none (#502).
  final List<EventRow> archived;

  /// The rows of [group].
  List<EventRow> of(EventGroup group) => switch (group) {
    EventGroup.upcoming => upcoming,
    EventGroup.planning => planning,
    EventGroup.past => past,
    EventGroup.archived => archived,
  };

  /// Whether every group is empty.
  bool get isEmpty =>
      upcoming.isEmpty && planning.isEmpty && past.isEmpty && archived.isEmpty;

  /// The [upcoming] rows still happening: a cancelled event is not. Home's
  /// shelf and a household's section show these and no others (#502, #503).
  List<EventRow> get stillHappening =>
      upcoming.where((row) => !row.cancelled).toList();

  @override
  List<Object?> get props => [upcoming, planning, past, archived];
}

/// Groups [items], the list's events in its order, against [now] (#497).
///
/// Only a date with a start counts. An event with one that hasn't
/// ended is upcoming; one whose every such date has ended is past; one with
/// none is planning. A date has ended once its end, or its start when it has
/// no end, is before [now], so a date ending at [now] is still upcoming.
///
/// Status decides only for an archived event, which is in the archived group
/// and no other (#502). Otherwise the dates decide: a Poll event is created
/// `planning` and nothing on the server changes its status once a date is
/// confirmed (backend#795), so the status would leave it in planning. The
/// dates an event counts are its confirmed ones, except while it has a
/// `cancelledAt`: then they are the dates its cancel took away, or the
/// confirmed ones while its cached dates predate the cancel, so a cancelled
/// event stays where it was and its row is marked cancelled.
///
/// [now] is a parameter because the groups move as time passes without any
/// write to the cache: an event that ends while the overview is open moves to
/// past at the next grouping, which [nextRegroupAt] says when to run.
/// Instants compare as instants, whatever zone they were read in.
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
  final archived = <(_Date?, EventRow)>[];

  for (final item in items) {
    final event = item.event;
    EventRow row(EventGroup group, {EventOccurrence? date}) => EventRow(
      event: event,
      group: group,
      date: date,
      dateBeingChosen:
          group == EventGroup.planning &&
          event.schedulingMode == EventSchedulingMode.poll &&
          event.status != EventStatus.cancelled,
      cancelled: wasCancelled(event),
      venue: _venue(date, event),
      householdName: householdNames[event.householdId],
      rsvp: switch (item.attendance?.status) {
        null || EventParticipationStatus.unknown => null,
        final status => status,
      },
    );

    final dates = _datesOf(item);
    if (event.status == EventStatus.archived) {
      final latest = dates.isEmpty
          ? null
          : dates.reduce((a, b) => _latestFirst(a, b) <= 0 ? a : b);
      archived.add((
        latest,
        row(EventGroup.archived, date: latest?.occurrence),
      ));
      continue;
    }

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

  // Dated rows first, latest first; the dateless keep the list's order.
  final dated = archived.where((a) => a.$1 != null).toList()
    ..sort((a, b) {
      final byStart = b.$1!.start.compareTo(a.$1!.start);
      return byStart != 0 ? byStart : a.$2.event.id.compareTo(b.$2.event.id);
    });

  return EventGroups(
    upcoming: [for (final (_, row) in upcoming) row],
    planning: planning,
    past: [for (final (_, row) in past) row],
    archived: [
      for (final (_, row) in dated) row,
      for (final (date, row) in archived)
        if (date == null) row,
    ],
  );
}

/// The first instant after [now] at which [groupEvents] over [items] answers
/// differently (#497): just past the earliest end among the dates that
/// haven't ended. At that instant an event moves to past, or shows its next
/// date. Null when no date's end lies ahead, so nothing will move.
DateTime? nextRegroupAt(List<EventListItem> items, {required DateTime now}) {
  DateTime? earliest;
  for (final item in items) {
    // An archived event's place never moves with time.
    if (item.event.status == EventStatus.archived) continue;
    for (final date in _datesOf(item)) {
      if (date.end.isBefore(now)) continue;
      if (earliest == null || date.end.isBefore(earliest)) earliest = date.end;
    }
  }
  // A date ending at an instant has not ended at it.
  return earliest?.add(const Duration(microseconds: 1));
}

/// A date that counts: an occurrence, its start, and when it is over, which
/// is its end, or its start when it has none.
typedef _Date = ({EventOccurrence occurrence, DateTime start, DateTime end});

/// [item]'s dates that count, in the occurrences' order (#502).
///
/// An event with a `cancelledAt` counts the cancelled dates whose own
/// `cancelledAt` is that same moment: the dates its cancel took away. A date
/// cancelled on its own earlier doesn't count. Archiving leaves `cancelledAt`
/// set, so a cancelled-then-archived event keeps the dates it lost, and a
/// reopen clears it. Every other event counts its confirmed dates.
///
/// An event with a `cancelledAt` that lost no dates counts its confirmed ones
/// instead. The server's cancel turns every confirmed date into a cancelled
/// one, so confirmed dates on a cancelled event were cached before the
/// cancel: its answer carries the event alone, and the dates stay as they
/// were until the re-read lands, or for good if that read fails. Counting
/// nothing would move the event to planning meanwhile.
List<_Date> _datesOf(EventListItem item) {
  if (item.event.cancelledAt case final lostAt?) {
    final lost = _datesWhere(
      item,
      (o) =>
          o.status == OccurrenceStatus.cancelled &&
          (o.cancelledAt?.isAtSameMomentAs(lostAt) ?? false),
    );
    if (lost.isNotEmpty) return lost;
  }
  return _datesWhere(item, (o) => o.status == OccurrenceStatus.confirmed);
}

/// [item]'s occurrences that [counts] takes and that have a start, in their
/// order.
List<_Date> _datesWhere(
  EventListItem item,
  bool Function(EventOccurrence) counts,
) => [
  for (final o in item.occurrences)
    if (o.startDate case final start? when counts(o))
      (occurrence: o, start: start, end: o.endDate ?? start),
];

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
