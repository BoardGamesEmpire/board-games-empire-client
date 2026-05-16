/// Status of a [SyncQueueEntry] in its lifecycle.
///
/// Client-only enum: never crosses the wire to the server. Serialization
/// uses the default `json_serializable` behaviour (Dart enum name),
/// producing `'pending'`, `'inProgress'`, `'failed'`, `'completed'`.
///
/// The pre-existing storage representation `'in_progress'` is migrated
/// to `'inProgress'` in schema v2 (Pass 2).
enum SyncStatus {
  /// Awaiting processing.
  pending,

  /// Currently being sent to the server.
  inProgress,

  /// Server rejected or network failure. Will retry.
  failed,

  /// Successfully synced. Entry can be purged.
  completed,
}
