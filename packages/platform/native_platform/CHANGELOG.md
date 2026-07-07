## 0.0.1

Initial internal release (#31).

* `NativePlatformBootstrap` implementing the `PlatformBootstrap` contract:
  encrypted meta database open, meta repositories, orchestrator composition
  and initialization, commit-on-success with non-masking rollback.
* `buildNativeServerContextFactory` composing storage + network installers
  per server context.
* User-confirmed destructive reset with key-before-file deletion ordering and
  sqlite companion-file cleanup.
* Constructor assertion enforcing a shared `EncryptionKeyService` between the
  injected `executorFactory` and `keyService`.
* Breadcrumb logging of secondary disposal failures during rollback/dispose.
