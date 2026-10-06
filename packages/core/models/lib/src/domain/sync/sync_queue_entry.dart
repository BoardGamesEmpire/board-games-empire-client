import 'package:freezed_annotation/freezed_annotation.dart';

import 'sync_operation.dart';
import 'sync_status.dart';

part 'sync_queue_entry.freezed.dart';
part 'sync_queue_entry.g.dart';

/// A pending write operation waiting to reach the server.
///
/// Entries are created immediately when the user performs an offline-capable
/// write. The sync engine processes them in [createdAt] order when
/// connectivity is available.
@freezed
abstract class SyncQueueEntry with _$SyncQueueEntry {
  const SyncQueueEntry._();

  const factory SyncQueueEntry({
    required String id,

    /// Serialised [SyncOperation]. Use [operation] to deserialize.
    required String payload,

    @Default(SyncStatus.pending) SyncStatus status,

    /// Number of send attempts. Capped at [maxRetries] before marking failed.
    @Default(0) int retryCount,

    /// Last error message for diagnostics. Null on first attempt.
    String? lastError,

    required DateTime createdAt,
    DateTime? lastAttemptAt,
  }) = _SyncQueueEntry;

  factory SyncQueueEntry.fromJson(Map<String, dynamic> json) =>
      _$SyncQueueEntryFromJson(json);

  static const int maxRetries = 5;

  /// How long a claim holds an entry before another sender may take it
  /// (#430). A sender that dies mid-send leaves its claim behind, and the
  /// lease is what frees it.
  ///
  /// Requests time out at 10s to connect plus 10s to receive, and the
  /// payloads are small JSON, so a live send finishes well inside this. A
  /// send that outlives it can be delivered twice. For every operation
  /// type the second delivery adds no data: household create is keyed
  /// (#131), adding to a collection is an upsert, an update writes
  /// absolute values, and a second remove reports already-removed. The
  /// one cost accepted is ordering: a late update can land after a newer
  /// one.
  static const Duration claimLease = Duration(minutes: 2);

  /// Deserializes the stored payload into a typed [SyncOperation].
  SyncOperation get operation => SyncOperation.deserialize(payload);

  bool get isPending => status == SyncStatus.pending;
  bool get isExhausted => retryCount >= maxRetries;
  bool get canRetry => status == SyncStatus.failed && !isExhausted;
}
