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
2. Best-effort inline send via `HouseholdRemoteDataSource.createHousehold`:
   - **success** → `HouseholdRepository.reconcileCreatedHousehold` swaps the
     optimistic id for the server's canonical id, clears the sync flags, and
     closes the queued op → `CreateHouseholdSuccess(pendingSync: false)`;
   - **failure** (transient *or* permanent) → the household stays queued for a
     later retry → `CreateHouseholdSuccess(pendingSync: true)`.

An unexpected *local* failure (the form prevents the only expected one, a
blank name) surfaces as `CreateHouseholdFailure`. The bloc is the only
coordinator — the repository never touches the network, and the remote never
touches storage.

## Offline-first

The queued `CreateHouseholdOperation` is the durable source of truth; the
inline send is only an accelerator. There is no sync-drain worker yet (#121),
so on any remote failure the household simply stays `isLocalOnly` and queued.
Distinguishing permanent rejections (rollback + cancel the queue entry) is
deferred to #121, which will own retry / failure / cancel semantics.

## Shape

- `CreateHouseholdScreen` — the entry point. Decoupled from DI: the caller
  passes the per-server `HouseholdRepository` and `HouseholdRemoteDataSource`
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
  `HouseholdRepository` + `HouseholdRemoteDataSource` from the **active**
  server scope's container.
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
