## Unreleased

* Stuck ops (#190): `SyncRecovery` retries or discards an op the server
  refused or that ran out of retries, undoing a discard's local effect
  through the repository that owns it; `StuckSyncOpsScreen` and
  `StuckSyncOpsNotice` show them. A drain purges completed entries older
  than a day on its first pass and at most hourly after, and
  `SyncQueueDrain.drainAfterChange` runs a pass that reads the queue after a
  write.

## 0.0.1

* Initial release (#121): `SyncOperationSenderImpl`, the one delivery path for
  every queued op, shared by the inline household create and the drain;
  `SyncQueueDrain`, which sends the queue on the session's re-hydrate triggers
  with per-entry ordering, a growing retry cooldown and a stop on server-level
  failures; and their installers. Native composes both; web composes the sender
  alone until #447.
