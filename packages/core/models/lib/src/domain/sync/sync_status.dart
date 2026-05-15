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
