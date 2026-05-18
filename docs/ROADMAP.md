# Board Games Empire — Client Roadmap

> Living document. Update as priorities shift, dependencies land, and the picture clarifies.
> Last meaningful update: post-Pass-9 PR-6 merge, May 2026.

This roadmap describes the path from the current foundation (offline-first
infrastructure, network layer, auth bloc, models, storage) to a device-installable
alpha and beyond. It complements the GitHub issue tracker — issues hold the
detailed scopes, this doc holds the *order*, *dependencies*, and *deferred
decisions*.

## Architectural ground truth

A short orientation for anyone (human or LLM) picking this up cold:

- **Multi-server.** A user can connect to multiple BGE servers. Each `ServerContext`
  has its own per-server Drift DB, dependency container (GetIt scoped), auth
  repository, and (future) WebSocket connection. The orchestrator manages
  active/backgrounded/monitoring/disposed lifecycle.
- **Self-hosted philosophy.** No third-party data sharing by default. Bug
  reports, analytics, and similar flows route to sinks the server admin
  configures via `/.well-known/bge-identity`. Users opt in.
- **Offline-first.** Mutations write locally + enqueue against a per-server
  sync queue. Reconciliation runs against server responses with surgical
  tombstone purges that defend against race conditions. The client DB is a
  *temporary cache*; the server is source of truth.
- **Three platforms in parallel from day one.** Android (primary alpha target),
  macOS desktop, browser. Storage and network are platform-split (drift_storage
  vs web_storage, dio_network vs web_network). No divergence.
- **Server discovery via `.well-known/bge-identity`.** The user enters a URL;
  the client fetches the identity document and learns the server's auth
  strategy, capabilities, version requirements, and configured sinks.
- **Privacy by default.** PII partial redaction in event logs, per-server
  encryption-at-rest, opt-in for any data leaving the device.

## What's done as of the merge of PR #6

- All Phase-1 models: Game, PlatformGame, GameCollection, Household,
  HouseholdMember, SyncOperation hierarchy.
- Drift schemas matching Prisma backend models, with partial unique indexes
  and tombstone semantics.
- Per-server `GameCollectionRepositoryImpl` with offline-first add/update/remove
  + sync queue + surgical reconcileFromServer + resurrection preserving play
  history.
- Per-server `HouseholdRepositoryImpl` (read-cache + cache-writer, with
  membership boundary gates). Mutations deferred to Phase 4.
- Per-server `GameRepositoryImpl` (read cache + cache writer, server-managed).
- `SyncQueueRepositoryImpl` with cuid2 ids, idempotent remap, atomic increments,
  exhausted-retry filtering, pending-count watch.
- `ServerContextImpl` skeleton with state machine (initializing → active →
  backgrounding → monitoring → disposed) and per-server GetIt container.
  Activate/suspend hooks have TODO(phase2) markers for DB lifecycle.
- `WellKnownClient` (discovery via `/.well-known/bge-identity`).
- `AuthRepositoryImpl` (dio_network, mobile/desktop bearer flow): signIn/signUp/
  getSession/signOut/watchAuthState, full DioException → AuthException mapping.
- `WebAuthRepositoryImpl` (web_network, cookie flow): equivalent shape.
- `TokenStorageService` with `flutter_secure_storage` (per-server keyed).
- `AuthBloc` with all event handlers and exception → user-message mapping.
- `auth_screen.dart` + widgets + l10n directory (i18n infrastructure exists).
- `MetaDatabase` + `ServerRepository` for `ServerConfig` persistence.
- Three Flutter apps scaffolded under `apps/{mobile,desktop,browser}/` (currently
  unmodified counter-template main.dart).

## What's NOT yet done (alpha-critical, in order)

### Phase 1 — App shell + observability foundation (~1-2 weeks)

**Goal**: replace counter-template main.dart in all three apps with a real
bootstrap that wires DI, theme, router, logging, and the meta DB. Lay the
prerequisite plumbing for everything after.

Tracked by:
- #7 Schema migration convention for Drift (prereq for any post-alpha schema work)
- #8 Observability foundation (logging + redaction + breadcrumb buffer + BugReport
  model) — **prerequisite for all bug reporting and analytics work**
- #14 Refactor AuthRepositoryImpl to accept injected Dio (DioFactory pattern)

Phase-1 also lands the app-shell scaffolding itself:
- `go_router` as new dep (confirmed)
- Theme tokens (light/dark), accessibility baseline (semantics, focus indicators,
  font scaling, contrast)
- i18n setup at app level matching `features/auth/l10n` pattern
- DI bootstrap via GetIt at app level
- Per-app `main.dart` that hands off to a shared `core/app_shell` package

Concerns to address during Phase 1:
- Backend CORS configuration (`'*'` + credentials is invalid for browsers).
  Tracked separately on backend side.
- The current `FlutterError.onError` / `PlatformDispatcher.instance.onError`
  paths must be wired to the observability layer once it lands.

### Phase 2 — First-run + Server add flow (~1 week)

**Goal**: a user opening the app for the first time can add a BGE server and
proceed to auth.

Tracked by:
- #13 Honor minClientVersion / maxClientVersion / features from well-known
- (informally) Server-add UX: single URL field + optional alias. The well-known
  discovery handles everything else.

UX:
- MetaDB empty → "Add Server" screen.
- User enters URL + optional alias → client calls `WellKnownClient.fetchIdentity`.
- On success: persist `ServerConfig` to MetaDB, trigger `ServerOrchestrator`
  to activate.
- Version negotiation fires before persist; mismatch surfaces a friendly error.
- Single-server alpha. No switcher UI. Data model supports many.

### Phase 3 — Auth wired end-to-end (~3-5 days)

**Goal**: existing `AuthBloc` bound to the active server's `AuthRepository`.

Tracked by:
- (no separate issue — wiring work, not new feature)

Steps:
- Bind AuthBloc to the active ServerContext's AuthRepository.
- Mount `auth_screen.dart` behind a router redirect when state is `Unauthenticated`.
- Verify the bloc-test path works against live backend on each platform.
- Account for #14 (DioFactory pattern) landing concurrently — the AuthBloc
  doesn't change, but the construction path does.

### Phase 4 — ServerContext lifecycle completion + per-server resources (~3-5 days, parallel-isable with Phase 3)

**Goal**: resolve the `TODO(phase2)` markers in `ServerContextImpl.activate()`
/ `suspend()`. Per-server Drift DB opens on activate, closes on suspend.

Tracked by:
- #16 Encryption-at-rest for per-server Drift databases via SQLCipher

Phase-4 lands:
- Activate opens DB, registers `AuthRepository` + `TokenStorageService` + dio
  client in the per-server `DependencyContainer`.
- Suspend reverses: dispose dio, close DB, unregister.
- DB open path uses SQLCipher with the per-server encryption key derived/loaded
  from secure storage.
- "Local DB unreadable" recovery path: delete + re-key + resync (the
  "client-as-cache" recovery story from #16).

### Phase 5 — Collection feature (~2 weeks)

**Goal**: game search → game detail → add-to-collection → collection list.
The sync queue gets its first real exercise.

Tracked by:
- (no separate issue yet — to be filed as the feature begins. Likely 4-5
  sub-issues: search screen, detail screen, collection list, add flow,
  sync-status indicators.)

Phase 5 lands:
- Backend game search integration (already exists server-side).
- Local search index for offline browsing of cached games.
- Add to collection (sync queue exercise).
- Reactive UI via existing `watch*` streams.
- Sync-status indicators (`isDirty` / `isLocalOnly` become visible state).
- First user of `UserDataExporter` (#11): `GameCollectionExporter`.

### Phase 6 — Hardening + Android packaging (~1 week)

**Goal**: device-installable alpha.

- Empty/loading/error states across all screens.
- Offline indicator (uses #9 connectivity service).
- A11y audit pass.
- Build configurations and signing for sideload-able Android APK.
- macOS and web builds confirmed working in CI.
- Documentation: per-platform dev-URL guide (LAN IP for Android device, `adb
  reverse` workflow, k8s deployment story).

## Cross-cutting Tier-1/2/3 work (lands throughout)

These don't define phases; they're concerns that thread through all phases:

- **#7 Schema migration convention** — established in Phase 1, used by every
  schema change after.
- **#8 Observability foundation** — Phase 1, used by everything after.
- **#9 Connectivity awareness service** — Phase 1 dep, integrated in Phase 4-6.
- **#10 Deep linking config + URL scheme** — Phase 1 manifest declarations,
  even before any actual deep links resolve to UI. Required to install in
  manifests pre-alpha.
- **#11 UserDataExporter interface** — Phase 1 interface; first exporter in
  Phase 5; more exporters per future feature.
- **#12 Clock skew correction** — Phase 4 (network responses available),
  integrated throughout post.
- **#15 Push notification interface** — Phase 1 interface stub; concrete
  implementations come post-alpha per platform.
- **#16 Encryption-at-rest** — Phase 4.
- **#17 Analytics interface** — Phase 1 interface (no implementations until
  post-alpha); enables the multi-sink architecture.

## What's deferred to post-alpha (v0.2+)

In rough order:

- **Household feature (CRUD + invites)**. Repository today is read-cache-only.
  Household mutation Phase begins with adding write methods to the interface,
  three new SyncOperation variants (CreateHousehold, AddMember, RemoveMember),
  and the membership-cache-stale-window strategy. Backend household management
  needs companion implementation.
- **Play sessions**. Session models exist as a future model; sessions UI is
  net-new. Timezone-aware datetimes become required here (`TZDateTime` from
  the `timezone` package).
- **Social** (friendship, events, RSVP). Largely new.
- **Real-time chat**. First real use of WebSockets. The
  `socket_io_client` package is already chosen. Repositories follow the
  abstract REST datasource pattern.
- **Push notification implementations** (per platform: FCM for Android, APNs
  for macOS, web-push or skip for browser).
- **Media handling** (profile images with crop/center, collection condition
  photos, event/session images + video, household banners). Multi-issue topic
  needing design before any issue can be filed. See "Design discussions
  pending" below.
- **Analytics implementations** + first event catalog rollout (#17 interface
  lands earlier; activation comes when analytics-sinks-in-well-known is
  wired and the catalog stabilizes).
- **Account deletion flow UI** (companion to backend account-deletion work).
- **Admin features** (audit log viewer, bug-report triage UI). These follow
  the backend admin endpoints landing.

## Design discussions still pending (not yet issues)

These topics have been decided as IN scope but the implementation shape needs
a focused design discussion before any GitHub issue can usefully be filed.

- **Media handling.** Multi-issue topic. Different rules for profile images
  (crop/resize controls), collection condition photos (multiple per item),
  event/session photos AND videos, household banners. Decisions to make:
  - Content-addressing strategy (avoid duplicate uploads).
  - Upload pipeline (resume on flaky connections, retry, sync-queue
    integration).
  - Image processing (crop, resize, EXIF stripping for privacy).
  - Video specifics (transcoding? streaming? size limits?).
  - Backend storage strategy (filesystem, S3-compatible, configurable).
  - CDN strategy.
  - Privacy posture (uploads stay on the user's server only; no central CDN).

  Probably becomes 6+ issues across client + backend once designed.

## Decisions documented elsewhere

For reference, these decisions are made but live in code/issue comments:

- **cuid2 for client-generated IDs.** Not Prisma's default v1 cuid; the backend
  uses cuid2 explicitly. Local row IDs round-trip through reconciliation; if
  the server replaces them, `SyncQueueRepository.remapCollectionId` rewrites
  pending ops.
- **Resurrection preserves play history.** Removing a game from a collection
  means "I don't own this anymore," not "I never played this." playCount /
  lastPlayed / playAgain / favorite carry across remove-readd cycles.
  rating/comment follow the live-row null-handling semantic (null = preserve).
- **PII partial redaction in event logs.** Emails like `j**n.d*e@email.com`,
  names like `J**n`. Deterministic so debug correlation works; documented
  caveat that it's incidental-exposure mitigation, not strong anonymization.
- **AuthState manual `==`/`hashCode`.** Sealed hierarchy without Equatable
  dep; only `AuthStateAuthenticated` needs value equality (session-based);
  const singletons handle the rest.
- **Single URL + optional alias for server-add UX.** Path-prefix deployments
  work because the full URL (scheme + host + optional port + optional path)
  is one field. The well-known discovery handles everything else.
- **Backend uses BetterAuth with bearer + email/password.** Opaque session
  tokens (no JWT). Sign-in/sign-up/get-session/sign-out endpoints under
  `/api/auth/...`. Other plugins installed (admin, anonymous, bearer,
  deviceAuthorization, genericOAuth, lastLoginMethod, oneTap, oneTimeToken,
  openAPI, twoFactor) but most not yet wired into client flow.

## Pointers

- **Issue tracker**: open issues in this repo, see Phase mappings above.
- **Backend roadmap**: `BoardGamesEmpire/board-games-empire-backend:docs/ROADMAP.md`.
- **Backend issue tracker**: `BoardGamesEmpire/board-games-empire-backend` —
  open issues #44-#49 cover backend Phase-1 prerequisites (bug-report stack,
  well-known extensions, audit log, analytics-sink-in-well-known).
