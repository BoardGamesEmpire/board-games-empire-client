import 'package:freezed_annotation/freezed_annotation.dart';

import 'event_attendee.dart';
import 'event_snapshot.dart';

part 'event_detail.freezed.dart';

/// One event as the detail screen shows it (#498): what
/// `EventRepository.getEvent` answers, with the current user's own row on its
/// roster.
///
/// Built by `EventRepository.watchEvent` from one transaction, so the
/// snapshot and the attendance it pairs with it always come from the same
/// state of the cache.
@freezed
abstract class EventDetail with _$EventDetail {
  const factory EventDetail({
    required EventSnapshot snapshot,

    /// What `EventRepository.getCurrentUserAttendance` answers: null where
    /// no cached roster names the current user. That is not the same as not
    /// attending, since only a detail read carries a roster until
    /// backend#867 puts the caller's attendance on every list row.
    EventAttendee? attendance,
  }) = _EventDetail;
}
