# Board Games Empire — Client Roadmap

> Living document. Update as priorities shift, dependencies land, and the picture clarifies.
> Last meaningful update: post-PR-22 (dio_network) merge, June 2026.

This roadmap describes the path from the current foundation (offline-first
infrastructure, network layer, auth bloc, models, storage, observability) to a
device-installable alpha and beyond. It complements the GitHub issue tracker —
issues hold the detailed scopes, this doc holds the *order*, *dependencies*, and
*deferred decisions*. The per-phase epics live at #23–#30.

## Architectural ground truth

A short orientation for anyone (human or LLM) picking this up cold:

- **Multi-server.** A user can connect to multiple BGE servers. Each `ServerContext`
  has its own per-server Drift DB, dependency container (GetIt scoped), auth
  repository, and (future) WebSocket connection. The orchestrator manages
  active/backgrounded/monitoring/disposed lifecycle. **Alpha ships single-server
  UX, but the multi-server infrastructure stays in place** — it is hard to retrofit.
- **Self-hosted philosophy.** No third-party data sharing by default. Bug
  reports, analytics, and similar flows route to sinks the server admin
  configures via `/.well-known/bge-identity`. Users opt in.
- **Offline-first infrastructure, online-first alpha UX.** Mutations write
  locally + enqueue against a per-server sync queue; reconciliation runs against
  server responses with surgical tombstone purges. The client DB is a *temporary
  cache*; the server is source of truth. The **infrastructure** is in place and
  exercised, but the polished **offline-first UX is deferred** — the alpha
  assumes connectivity for mutations and guarantees cached reads.
- **Three platforms in parallel from day one.** Android (primary alpha target),
  macOS desktop, browser. Storage and network are platform-split (drift_storage
  vs web_storage, dio_network vs web_network). No divergence.
- **REST for alpha; WebSocket later.** The backend exposes REST for everything in
  alpha scope (search/import are explicitly documented as the REST fallback for a
  future WS flow). `socket_io_client` and the WS layer are a post-alpha enhancement.
- **Server discovery via `.well-known/bge-identity`.** The user enters a URL; the
  client fetches the identity document and learns the server's auth strategy,
  capabilities, and (once backend #47 lands) version requirements + configured sinks.
- **Privacy by default.** PII partial redaction in event logs, per-server
  encryption-at-rest, opt-in for any data leaving the device.

## What's done (merged to master)

- All Phase-1 models: Game, PlatformGame, GameCollection, Household,
  HouseholdMember, SyncOperation hierarchy (PR #6).
- Drift schemas matching Prisma backend models, with partial unique indexes and
  tombstone semantics; UTC-preserving ISO-8601 datetime storage (PR #21).
- Per-server `GameCollectionRepositoryImpl` — offline-first add/update/remove +
  sync queue + surgical reconcileFromServer + resurrection preserving play history.
- Per-server `HouseholdRepositoryImpl` (read-cache + cache-writer). Write methods
  land in P4.
- Per-server `GameRepositoryImpl` (read cache + cache writer, server-managed).
- `SyncQueueRepositoryImpl` — cuid2 ids, idempotent remap, atomic increments,
  exhausted-retry filtering, pending-count watch.
- `ServerContextImpl` skeleton with state machine and per-server GetIt container.
  Activate/suspend still carry `TODO(phase2)` DB-lifecycle markers (closed in P3).
- `WellKnownClient` (discovery via `/.well-known/bge-identity`).
- `AuthRepositoryImpl` (dio_network, bearer) + `WebAuthRepositoryImpl` (web_network,
  cookie); `TokenStorageService` (`flutter_secure_storage`, per-server keyed);
  `AuthBloc` with full event + exception→message mapping; `auth_screen.dart` + i18n.
- `MetaDatabase` + `ServerRepository` for `ServerConfig` persistence.
- **Observability foundation (PR #20, closes #8):** `BgeLogger`, `Redaction`,
  `BreadcrumbBuffer`, `FeedbackReport`/`FeedbackService` domain.
- **DioFactory / `dio_network` (PR #22, closes #14):** `DioFactory`,
  `DefaultDioFactory`, `TokenInterceptor`, per-platform registration; refactored
  auth repos.
- Three Flutter apps scaffolded under `apps/{mobile,desktop,browser}/` — **still
  the counter-template `main.dart`** (replaced in P0).

## Alpha scope (confirmed)

A new user can: **add a server → sign in → create a household → (admin) add & connect
gateways → search/browse games (in-system and external) → import an external game →
add games to a personal collection → and it all persists across restarts.** Written
against REST, single-server UX, multi-server + offline-write infrastructure in place.
Events, play sessions, social, chat, media, and offline-first UX are **deferred**.

## Path to alpha — phases (epics #23–#30)

### P0 — App shell + cross-cutting foundation (#23)

Replace the counter-template `main.dart` ×3 with a real bootstrap; land the
retrofit-hard infrastructure.

- #31 ~~App shell package + `go_router` + DI bootstrap + `main.dart` ×3~~
- #32 Theme tokens (light/dark) + accessibility baseline
- #33 App-level i18n
- #34 ~~Global error handling → observability wiring~~
- #35 `BuildInfo` service (client version)
- #7 ~~Schema migration convention (Drift) — **blocker**~~
- #9 Connectivity awareness service — **blocker**
- #10 Deep-link URL scheme + manifests — **interface/manifest-only**
- #11 UserDataExporter interface — **interface-only**
- #15 Push notification interface — **interface-only**
- #17 Analytics interface — **interface-only**

### P1 — Server discovery & add flow (#24)

- #36 Server-add discovery flow (UI + `WellKnownClient` + persist + activate)
- #13 Honor `minClientVersion` / `maxClientVersion` / `features` — **depends on
  backend #47**; reconcile `ServerIdentity` to the real `BgeDiscoveryDto`
  (`bge*` snake_case keys + `strategies[]`).

### P2 — Auth wired end-to-end (#25)

- #37 Bind `AuthBloc` to the active server's `AuthRepository` + router gate.
  Email/password only for alpha (passkey/2FA/anonymous advertised but out of scope).

### P3 — ServerContext lifecycle + encryption (#26)

- #38 Lifecycle completion: per-server DB open/close + container registration.
- #16 ~~Encryption-at-rest (SQLCipher, per-server key) — **blocker** (encrypted
  from day one; hard to retrofit). Includes the delete+re-key+resync recovery path.~~
- #12 Clock-skew correction — **interface-only / defer**.

### P4 — Households (create) (#27) — parallelizable

Collections are `userId`-scoped, so households are not a hard dependency for the
collection path.

- #39 Household write methods + `CreateHousehold` sync operation
- #40 Create-household UI

Backend: `POST /households` exists. Membership/invites deferred.

### P5 — Gateways admin + game discovery (#28)

- #41 Gateway admin UI (role-gated): list / add / connect / disconnect
- #42 Game browse + search UI (in-system + external gateway results)
- #43 Game import flow + completion handling (REST) — **depends on backend #115**

Backend: `game-gateways` CRUD + connect/disconnect, `GET /games/search`
(local+external unified), `GET /games`, `POST /games/import` (async) all exist.

### P6 — Collection feature (#29) — critical-path long pole

**Backend-blocked on #114 (GameCollection REST CRUD — net-new server work).**

- #44 Collection list (reactive read)
- #45 Add-to-collection (`platformGameId` + `GameMedium` + quantity)
- #46 Collection item detail / edit / remove (resurrection-aware)
- #47 Sync-status indicators (`isDirty` / `isLocalOnly` / pending count)
- #48 `GameCollectionExporter` (first `UserDataExporter` impl)

Collections key on **`platformGameId` + `medium`** (not `gameId`); remove→re-add
preserves play history.

### P7 — Hardening + Android packaging (#30)

- #49 Empty / loading / error states + offline indicator (#9)
- #50 Accessibility audit pass (WCAG 2.1 AA)
- #51 Android sideload packaging + signing + macOS/web CI + dev-URL docs

## Critical path

`P0 → P1 → P2 → P3 → P6`, with **backend #114 (collection CRUD) started
immediately** so it is ready by the time P6 lands. P4 (households) and P5
(gateways/search/import) run in parallel. The "anything hard to retrofit, even if
it delays a functional alpha" rule pulls P3 encryption, P0 migrations, and the
multi-server infra ahead of the first satisfying end-to-end demo — a deliberate
tradeoff.

## Backend dependencies

- **#114 — GameCollection REST CRUD** (new). Hard blocker for P6. No collection
  controller exists server-side today (`games` is the admin catalog).
- **#115 — REST import-status endpoint** (new). Import is async; the REST-only
  alpha needs to observe completion (P5).
- **#47 — well-known version/features/sinks** (existing). Client #13 (P1) consumes
  it; degrades gracefully (open bounds) until it lands.
- Already present and consumed as-is: auth (BetterAuth), households CRUD,
  game-gateways CRUD + connect/disconnect, `games/search` (local + external),
  `games/import`, `games` catalog, `.well-known/bge-identity`.

## What's deferred to post-alpha (v0.2+)

In rough order:

- **Offline-first UX** (the polished experience on top of the existing infra).
- **WebSocket layer** (search/import live updates, then real-time chat) via
  `socket_io_client`; REST paths remain the documented fallback.
- **Household membership + invitations** (AddMember/RemoveMember sync variants,
  membership-cache-stale-window strategy). Create-only for alpha.
- **Play sessions** (timezone-aware datetimes via the `timezone` package).
- **Events / social** (friendship, events, RSVP).
- **Push notification implementations** (FCM/APNs/web-push; interface stub only in P0).
- **Media handling** (profile images, condition photos, event/session media,
  banners). Still needs a focused design pass — see below.
- **Analytics implementations** + event catalog rollout (interface only in P0).
- **Account deletion flow UI**; **admin features** (audit log, feedback triage).

## Design discussions still pending (not yet issues)

- **Media handling.** Multi-issue topic (client + backend). Decisions: content
  addressing, resumable upload pipeline + sync-queue integration, image processing
  (crop/resize/EXIF-strip), video specifics, backend storage strategy
  (filesystem / S3-compatible / configurable), CDN, privacy posture. Note the
  backend already has a `MediaModule` + `media` models; a design pass should
  reconcile the client story against what exists server-side before filing.

## Decisions documented elsewhere

- **cuid2 for client-generated IDs.** `SyncQueueRepository.remapCollectionId`
  rewrites pending ops if the server replaces a local id.
- **Resurrection preserves play history.** Remove = "no longer owned," not "never
  played." playCount/lastPlayed/playAgain/favorite carry across remove-readd;
  rating/comment follow null=preserve.
- **PII partial redaction in event logs.** Deterministic incidental-exposure
  mitigation, not strong anonymization.
- **AuthState manual `==`/`hashCode`.** Sealed hierarchy, no Equatable dep.
- **Single URL + optional alias for server-add.** The full URL is one field;
  well-known discovery handles the rest.
- **Backend uses BetterAuth** (bearer + email/password, opaque session tokens).
  Passkey/2FA/anonymous advertised via `bge*Supported`; not wired into alpha UX.
- **Collections key on `platformGameId` + `medium`.** A `PlatformGame` is a
  platform incarnation of a `Game` ("Catan on Tabletop" vs "Catan on Steam");
  search/import must resolve a `platformGameId` before add.

## Pointers

- **Issue tracker**: epics #23–#30; sub-issues #31–#51; cross-cutting #7, #9–#13, #15–#17.
- **Backend companions**: `BoardGamesEmpire/board-games-empire-backend#114`
  (collection CRUD), `#115` (import status), `#47` (well-known extension).
- **Backend roadmap**: `BoardGamesEmpire/board-games-empire-backend:docs/ROADMAP.md`
  (not yet created — companion still TBD).
