import 'package:freezed_annotation/freezed_annotation.dart';

import 'event.dart';
import 'event_attendee.dart';
import 'event_occurrence.dart';
import 'event_policy.dart';

part 'event_snapshot.freezed.dart';

/// One event as one read returned it: the event, its occurrences, and the
/// policy and roster when that read carried them (#496).
///
/// The list read (`GET /events`) and the detail read (`GET /events/:id`) do not
/// return the same parts, and a snapshot records which it got, so a reader can
/// tell what the server said from what it left out.
@freezed
abstract class EventSnapshot with _$EventSnapshot {
  const factory EventSnapshot({
    required Event event,
    required List<EventOccurrence> occurrences,

    /// Null when the event has no policy, or the caller may not read it.
    EventPolicy? policy,

    /// The roster, in three states that must stay apart.
    ///
    /// Null means the read carried no roster at all, as `GET /events` does, so
    /// it says nothing about who is on it. An empty list means the read carried
    /// one that the caller cannot read, which is not the same as nobody being
    /// on it. Anything else is the roster itself.
    ///
    /// This is nullable rather than defaulting to an empty list for that
    /// reason: a default would turn "not asked" into "nobody".
    List<EventAttendee>? attendees,
  }) = _EventSnapshot;
}
