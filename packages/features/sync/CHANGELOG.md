## 0.0.1

* Initial release (#121): `SyncOperationSenderImpl`, the one delivery path for
  every queued op, shared by the inline household create and the drain;
  `SyncQueueDrain`, which sends the queue on the session's re-hydrate triggers
  with per-entry ordering, a growing retry cooldown and a stop on server-level
  failures; and their installers. Native composes both; web composes the sender
  alone until #447.
