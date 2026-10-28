import 'package:freezed_annotation/freezed_annotation.dart';

import 'occurrence_status.dart';

part 'event_occurrence.freezed.dart';

/// One occurrence of an [Event]: when it happens, and where if that differs
/// from the event's own place (#496).
///
/// A fixed event has one occurrence and a multi-day event has several. While an
/// availability poll runs, an event's occurrences are proposals
/// ([OccurrenceStatus.proposed]) until the host confirms one.
@freezed
abstract class EventOccurrence with _$EventOccurrence {
  const factory EventOccurrence({
    required String id,
    required String eventId,

    /// A name for this occurrence, such as "Day 1" or "Saturday Evening".
    String? label,

    /// Null means the date is still to be set.
    DateTime? startDate,

    /// Null while the date is still to be set, and for an occurrence that has a
    /// start but no end.
    DateTime? endDate,

    /// Overrides the event's place for this occurrence alone.
    String? location,
    required OccurrenceStatus status,

    /// Where this occurrence falls among the event's, lowest first. Occurrences
    /// that share a value are ordered by id.
    required int sortOrder,

    /// When a proposed occurrence was confirmed. Null for one created already
    /// confirmed, as in a fixed or multi-day event.
    DateTime? confirmedAt,
    DateTime? declinedAt,
    DateTime? cancelledAt,

    /// Why a cancelled date was cancelled, when the canceller gave a reason
    /// (backend#795).
    String? cancelReason,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _EventOccurrence;
}
