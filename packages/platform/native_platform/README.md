# native_platform

The shared native (mobile + desktop) composition root for Board Games Empire.

Implements the `PlatformBootstrap` contract from `app_shell` by composing the
concrete storage and network packages that native platforms use.
`mobile_platform` and `desktop_platform` are thin subclasses of
`NativePlatformBootstrap`; they exist as hook points for platform-specific
concerns (connectivity, window/tray management, deep-link registration) but
share this bootstrap for the alpha scope.

## Responsibilities

- **`NativePlatformBootstrap`** — opens the encrypted meta database
  (`EncryptedExecutorFactory` → `MetaDatabase`), builds the meta repositories,
  composes the per-server `ServerContextFactory`, and constructs and
  initializes the `ServerOrchestrator`. State is committed only on success;
  a failed attempt rolls back without masking the original error, logging any
  secondary disposal failure as a breadcrumb.
- **`buildNativeServerContextFactory`** — wires each server context with the
  storage installer (encrypted DB open + one-shot key recovery) followed by
  the network installer.
- **Reset** — the user-confirmed destructive recovery: deletes the meta
  encryption key *before* the database file (and its `-wal`/`-shm`/`-journal`
  companions), matching the storage layer's recovery ordering. Never invoked
  automatically.

## Invariants

- If you inject an `executorFactory` you must also inject the `keyService` it
  was built with: the meta executor and the per-server installers must share
  one `EncryptionKeyService`, enforced by a constructor assertion.
- Every collaborator is injectable with a production default, so the
  composition is unit-testable without a real keychain or filesystem.

## Entry point

Consumed indirectly — apps depend on `mobile_platform` / `desktop_platform`,
which subclass `NativePlatformBootstrap` and pass it to `runBgeApp`.

Part of the Board Games Empire client monorepo; not published to pub.dev.
