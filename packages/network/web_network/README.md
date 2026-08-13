# web_network

The browser network stack for Board Games Empire (#96).

Implements the `network_interface` contracts for the web, where two
constraints change the shape of everything: the app can only talk to the
origin in the address bar, and the BetterAuth session lives in an httpOnly
cookie the browser owns and Dart can never read. There is therefore no token
storage, no token interceptor, no meta database, no persisted `ServerConfig`,
and no orchestrator.

Depends on `dio_network` only for the platform-neutral `DioFactory` seam and
the two clients that are genuinely shared (`WellKnownClientImpl`,
`FeedbackDioTransport`); the native token plumbing is not imported.

## Responsibilities

- **`bootstrapWebServerScope`** — the web composition root's single entry
  point. Resolves the origin, fetches its `/.well-known/bge-identity` through
  the `WellKnownClient` seam, builds an isolated per-server
  `DependencyContainer`, and returns the scope holding it.
- **`registerServerNetworkWeb`** — populates that container with the shared
  `Dio` and the `AuthRepository`. Takes a `ServerIdentity` directly rather
  than a `ServerConfig`, since the web has nothing persisted to read one from.
- **`WebDioFactory`** — enables `withCredentials` so the browser sends the
  session cookie, and passes no token interceptor. The base URL comes from
  the address bar via `Uri.base.origin`, not from `ServerConfig.serverUrl`.
- **`WebAuthRepositoryImpl`** — cookie-only auth. `getCachedSession`
  delegates to `getSession`, because an httpOnly cookie is opaque to Dart.
- **`WebActiveServerScope`** — a constant single-value `ActiveServerScope`:
  `active` is always non-null and `watchActive` replays that one value and
  never emits again. Deliberately not a degenerate orchestrator, and
  deliberately with no path that emits `null`.

## Invariants

- The container owns the shared `Dio` and closes it on dispose. Clients
  registered into it must not close a `Dio` they share.
- `Uri.base` has no origin on the Dart VM, so every origin-resolving entry
  point takes an injectable `originProvider` that defaults to the browser's
  — which is also how the tests run off-browser.

## Entry point

Consumed by `web_platform`'s `WebPlatformBootstrap`, not by apps directly.

Part of the Board Games Empire client monorepo; not published to pub.dev.
