/// What each date of an event offers, by its status and the event's (#506).
///
/// The role table ([EventAction]) knows who may confirm, decline, cancel, edit,
/// remove and add a date, and leaves the status to the screen: the server
/// refuses a confirm on a date that isn't proposed, so the client offers only
/// what it will grant. These helpers narrow the table's answer by status, so
/// the screen shows a control only when both agree.
library;

import 'package:models/domain.dart';

import 'event_actions.dart';

/// The date actions [allowed] (from eventActionsFor) leaves for [occurrence]
/// on [event], by status (#506): any of editDate, confirmDate, declineDate,
/// cancelDate, removeDate. Unmodifiable.
///
/// Confirm and decline are for a proposed date that hasn't passed
/// ([proposalHasPassed]) and cancel for a confirmed one. Edit and remove fit a
/// date of any status, and an edit to a later time reopens one that has passed.
/// A cancelled or archived event takes no date write, and neither does an event
/// or date of unknown status, which the client can't judge.
Set<EventAction> dateActionsFor(
  Event event,
  EventOccurrence occurrence,
  Set<EventAction> allowed, {
  required DateTime now,
}) {
  if (!takesDateWrites(event)) return const {};

  final byStatus = switch (occurrence.status) {
    OccurrenceStatus.proposed when proposalHasPassed(occurrence, now) => const {
      EventAction.editDate,
      EventAction.removeDate,
    },
    OccurrenceStatus.proposed => const {
      EventAction.editDate,
      EventAction.confirmDate,
      EventAction.declineDate,
      EventAction.removeDate,
    },
    OccurrenceStatus.confirmed => const {
      EventAction.editDate,
      EventAction.cancelDate,
      EventAction.removeDate,
    },
    OccurrenceStatus.declined || OccurrenceStatus.cancelled => const {
      EventAction.editDate,
      EventAction.removeDate,
    },
    OccurrenceStatus.unknown => const <EventAction>{},
  };

  return Set.unmodifiable(byStatus.intersection(allowed));
}

/// Whether [occurrence] is a proposed date whose time has gone by, as of [now].
///
/// Worked out here because the status can't say: the server leaves a date
/// Proposed until a host acts on it, however long ago it was. A date ends as
/// `groupEvents` says: at its end, or its start when it has none, and a date
/// ending at [now] has not passed. One with no start has no time to pass.
bool proposalHasPassed(EventOccurrence occurrence, DateTime now) {
  if (occurrence.status != OccurrenceStatus.proposed) return false;

  final start = occurrence.startDate;
  if (start == null) return false;
  return (occurrence.endDate ?? start).isBefore(now);
}

/// Whether [event], holding [occurrences], offers Add a date.
///
/// A fixed event holds one date, so it offers Add only while it has none. A
/// cancelled date counts, as the server counts it (backend#966). A poll or
/// multi-day event takes as many as the host likes.
bool canAddDate(
  Event event,
  List<EventOccurrence> occurrences,
  Set<EventAction> allowed,
) {
  if (!allowed.contains(EventAction.addDate)) return false;
  if (!takesDateWrites(event)) return false;

  return switch (event.schedulingMode) {
    EventSchedulingMode.fixed => occurrences.isEmpty,
    EventSchedulingMode.poll || EventSchedulingMode.multiDay => true,
    EventSchedulingMode.unknown => false,
  };
}

/// The sortOrder an added date takes: one past the highest, or 0.
int nextSortOrder(List<EventOccurrence> occurrences) {
  if (occurrences.isEmpty) return 0;

  return occurrences
          .map((occurrence) => occurrence.sortOrder)
          .reduce((a, b) => a > b ? a : b) +
      1;
}

/// Whether [event] takes a date write at all: not once cancelled or
/// archived, nor while its status is unknown.
bool takesDateWrites(Event event) => switch (event.status) {
  EventStatus.cancelled || EventStatus.archived || EventStatus.unknown => false,
  EventStatus.completed ||
  EventStatus.ongoing ||
  EventStatus.planning ||
  EventStatus.scheduled => true,
};
