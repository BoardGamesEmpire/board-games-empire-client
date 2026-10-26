import 'package:freezed_annotation/freezed_annotation.dart';

import '../common/reach.dart';
import 'event_scheduling_mode.dart';
import 'event_status.dart';
import 'event_type.dart';

part 'event.freezed.dart';

/// A planned gathering of players, as the server describes it and the device
/// caches it for the signed-in user (#496).
///
/// The event holds what is true of the whole gathering. Its dates are
/// [EventOccurrence]s, its roster [EventAttendee]s and its rules an
/// [EventPolicy]; an [EventSnapshot] carries the parts one read returned.
///
/// ## What is deliberately not here
///
/// The cancellation and deletion audit fields (`cancelledById`,
/// `cancelReason`, `deletedById`) and the recurrence fields are out of scope
/// for the data layer (#496). There is no `deletedAt` either, because neither
/// read serves a soft-deleted event.
@freezed
abstract class Event with _$Event {
  const factory Event({
    required String id,
    required String title,

    /// The account that created the event.
    required String createdById,

    /// The household the event belongs to. Null for an event outside any
    /// household.
    String? householdId,
    String? description,
    String? image,

    /// The event-level place. An occurrence may override it with its own.
    String? location,
    String? url,
    required EventType type,
    required Reach reach,
    required EventStatus status,
    required EventSchedulingMode schedulingMode,

    /// True when this event has local changes not yet synced to the server.
    /// Only a create sets it yet, with [isLocalOnly], on the event it writes
    /// (#499).
    @Default(false) bool isDirty,

    /// True when this event was created on this device and the server has
    /// not yet confirmed it (#499). The reconcile replaces it with the
    /// server's copy, which carries neither flag.
    @Default(false) bool isLocalOnly,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _Event;
}
