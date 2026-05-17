/// Status of a [SyncQueueEntry] in its lifecycle.
///
/// Client-only enum: never crosses the wire to the server.
/// Serialization uses the default `json_serializable` behaviour
/// (Dart enum name), producing `'pending'`, `'inProgress'`,
/// `'failed'`, `'completed'`. The Drift mapper in
/// `SyncQueueRepositoryImpl` reads and writes the same string
/// form, so JSON and storage agree.
///
/// Pre-production, the storage schema is at version 1 and is
/// applied destructively — there is no v1→v2 migration step and no
/// legacy values to translate. The storage layer's `_parseStatus`
/// recognises only the canonical camelCase names and throws
/// `StateError` on anything else, so an unknown value surfaces as
/// corruption rather than being silently coerced into
/// `SyncStatus.pending`.
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
