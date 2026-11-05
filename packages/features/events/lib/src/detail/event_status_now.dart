import 'package:models/domain.dart';

/// [event]'s status as of [now], worked out from its cached dates (#502).
///
/// Archived, cancelled and unknown come from `Event.status` as cached: only a
/// write changes them, and the detail reads again after every write. Any other
/// status is worked out as the server works it out: only a confirmed date with
/// a start counts, and a date ends at its end, or at its start when it has no
/// end or an end before it. With no such date the event is planning. Before
/// the earliest start it is scheduled, from then until the latest end it is
/// ongoing, and from the latest end on it is completed, so a date ending at
/// [now] has ended.
///
/// Worked out here rather than read from the cache because the status moves
/// as time passes without any write: an event that ends while its screen is
/// open, or while the device is offline, must stop saying scheduled. Instants
/// compare as instants, whatever zone they were read in. [nextDetailBoundary]
/// says when to ask again.
EventStatus eventStatusAt(
  Event event,
  List<EventOccurrence> occurrences, {
  required DateTime now,
}) {
  if (!_isDerived(event)) return event.status;

  final span = _confirmedSpan(occurrences);
  if (span == null) return EventStatus.planning;
  if (now.isBefore(span.start)) return EventStatus.scheduled;
  return now.isBefore(span.end) ? EventStatus.ongoing : EventStatus.completed;
}

/// Whether [event] says it was cancelled (#502): it is, or it was cancelled
/// before it was archived. The server's archive keeps the cancel's time and
/// reason, so the overview's row and the detail's header both say so of an
/// archived event that has them.
bool wasCancelled(Event event) => switch (event.status) {
  EventStatus.cancelled => true,
  EventStatus.archived => event.cancelledAt != null,
  _ => false,
};

/// The first instant after [now] at which the detail has to be built again
/// (#502, #655): the earliest of the next start and the next end when
/// [eventStatusAt] is worked out from the dates, and of the moment each
/// proposed date passes, as `proposalHasPassed` has it: just past its end, or
/// its start when it has none. Null when none of them lies ahead, so nothing
/// will change.
///
/// A cancelled or archived event has no start or end to wait for, but a
/// proposed date on it still passes, so that boundary stays.
DateTime? nextDetailBoundary(
  Event event,
  List<EventOccurrence> occurrences, {
  required DateTime now,
}) {
  DateTime? earliest;
  void consider(DateTime at) {
    if (!at.isAfter(now)) return;
    if (earliest == null || at.isBefore(earliest!)) earliest = at;
  }

  if (_isDerived(event)) {
    final span = _confirmedSpan(occurrences);
    if (span != null) {
      consider(span.start);
      consider(span.end);
    }
  }

  for (final o in occurrences) {
    if (o.status != OccurrenceStatus.proposed) continue;
    final start = o.startDate;
    if (start == null) continue;
    // A date ending at an instant has not passed at it.
    consider((o.endDate ?? start).add(const Duration(microseconds: 1)));
  }
  return earliest;
}

/// Whether [event]'s status is worked out from its dates, not read as cached.
///
/// No wildcard, so a status the server adds has to be placed here, as it
/// has to be in `takesDateWrites`.
bool _isDerived(Event event) => switch (event.status) {
  EventStatus.archived || EventStatus.cancelled || EventStatus.unknown => false,
  EventStatus.planning ||
  EventStatus.scheduled ||
  EventStatus.ongoing ||
  EventStatus.completed => true,
};

/// The earliest start and the latest end among the confirmed dates that have
/// a start. A date's end is its start when it has no end or one before it.
/// Null when no date counts.
({DateTime start, DateTime end})? _confirmedSpan(
  List<EventOccurrence> occurrences,
) {
  DateTime? earliestStart;
  DateTime? latestEnd;
  for (final o in occurrences) {
    final start = o.startDate;
    if (o.status != OccurrenceStatus.confirmed || start == null) continue;
    final rawEnd = o.endDate;
    final end = rawEnd != null && rawEnd.isAfter(start) ? rawEnd : start;
    if (earliestStart == null || start.isBefore(earliestStart)) {
      earliestStart = start;
    }
    if (latestEnd == null || end.isAfter(latestEnd)) latestEnd = end;
  }
  if (earliestStart == null || latestEnd == null) return null;
  return (start: earliestStart, end: latestEnd);
}
