# household

Create-household feature (#27 / #40): a signed-in user creates — and owns —
a household that survives restart. Households are the first domain that
round-trips to the server, so this feature is also the reference for the
online-first optimistic-write path.

## Flow

`CreateHouseholdBloc` is the coordinator. On submit:

1. `HouseholdRepository.create` writes the household optimistically
   (`isLocalOnly = true`) plus a synthesized `HouseholdOwner` member row, and
   enqueues a `CreateHouseholdOperation` — one transaction. The household is
   visible from this point (the read gate needs the member row).
2. Best-effort inline send of the op as `create` queued it, through
   `SyncOperationSender.deliver`, the one delivery path the sync queue's drain
   takes too (#121). It claims the queued op, sends it keyed by its `localId`
   (#131), and records the outcome:
   - **delivered** → `HouseholdRepository.reconcileCreatedHousehold` has
     swapped the optimistic id for the server's canonical id, cleared the
     sync flags, and closed the queued op →
     `CreateHouseholdSuccess(pendingSync: false)`;
   - **anything else** → the household stays queued, and the sender has
     recorded why on the queue entry → `CreateHouseholdSuccess(pendingSync:
     true)`.

An unexpected *local* failure (the form prevents the only expected one, a
blank name) surfaces as `CreateHouseholdFailure`. The bloc is the only
coordinator — the repository never touches the network, and the remote never
touches storage.

## Offline-first

The queued `CreateHouseholdOperation` is the durable source of truth; the
inline send is only an accelerator. On native, the sync queue's drain
(`packages/features/sync`, #121) sends what the inline send could not, on the
session's re-hydrate triggers. On web it does not yet (#447), so a web create
whose inline send fails stays queued.

A create the server refuses as it stands is **parked**, not rolled back: the
household stays `isLocalOnly`, its op stays queued with the server's error,
and nothing sends it again until someone retries or discards it by hand
(#190). The list's pending badge shows it as unsynced throughout.

## Shape

- `CreateHouseholdScreen` — the entry point. Decoupled from DI: the caller
  passes the per-user `HouseholdRepository` and `SyncOperationSender`
  (resolved from the active server scope); the screen provides the bloc.
- `CreateHouseholdBloc` / `CreateHouseholdEvent` / `CreateHouseholdState` —
  sealed events and states; success carries the `householdId` and a
  `pendingSync` flag.
- `CreateHouseholdForm` — `reactive_forms` over a locally-owned `FormGroup`
  (name required, description optional). Values are read and validated at
  submit. One `valueChanges` subscription, which fires `onEdited` so the
  screen can retire a spent error banner: bound to bloc state, it does not
  fade the way a SnackBar would, so it would otherwise keep complaining
  about the name the user is replacing (#191).

## Wiring (owned by `app_shell` / platform composition)

- **Route**: supply `CreateHouseholdScreen` to its route, resolving
  `HouseholdRepository` + `SyncOperationSender` from the **active** server
  scope's container. The sender is registered by `SyncSenderInstaller` from
  `packages/features/sync`, which runs after `UserSessionScopeInstaller` in
  the per-*user* installer list.
- **Scope**: add `UserSessionScopeInstaller()` (renamed from
  `HouseholdScopeInstaller` in #150) to the per-*user* installer list — it
  registers `SyncQueueRepository`, `HouseholdRepository` and
  `GameCollectionRepository`. It resolves the database, clock and cached
  session from the per-*server* tier, but that ordering is structural, not
  positional: a per-server scope is always fully installed before any user
  session can activate, so position within either list carries no
  constraint. The `HouseholdRemoteDataSource` is registered by
  `registerServerNetwork` (it shares the per-server Dio).
- **l10n**: register `HouseholdLocalizations.delegate` in the app's
  `localizationsDelegates`.

## Accessibility

Labeled fields (never hint-only), a required-name validation message, keyboard
operability (name → next, description → done submits), and a submit button
that is disabled (not hidden) and shows a spinner while in flight.

## i18n

All copy comes from `HouseholdLocalizations` (gitignored, regenerated —
`melos run generate`).

## Not in scope here

Sync-status indicators on the household list (#47), deferred create fields —
language / visibility (#123), household image (#124), membership sync + owner
member id reconciliation (#122), and the web write-path parity (#125).
