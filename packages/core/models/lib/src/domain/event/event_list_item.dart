import 'package:freezed_annotation/freezed_annotation.dart';

import 'event.dart';
import 'event_attendance.dart';
import 'event_occurrence.dart';

part 'event_list_item.freezed.dart';

/// One event on the user's list, with what it takes to place and show it
/// (#497): its dates, and the user's own place on its roster.
///
/// Built by `EventRepository.watchAttendingEventListItems` from one join, so a
/// change to an event, its dates or the user's attendance reaches the list
/// as one emission. Which dates count, and which group the event falls in,
/// is the events feature's to decide, against the current time.
@freezed
abstract class EventListItem with _$EventListItem {
  const factory EventListItem({
    required Event event,

    /// Every cached occurrence, in the server's order: sortOrder, then id.
    required List<EventOccurrence> occurrences,

    /// The current user's own attendance: what the list read carried for
    /// them, else their own row on the cached roster. Null when neither
    /// names them, which means not known.
    EventAttendance? attendance,
  }) = _EventListItem;
}
