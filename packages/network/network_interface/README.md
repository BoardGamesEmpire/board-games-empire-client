# network_interface

The platform-neutral network contracts for Board Games Empire.

Pure Dart abstractions and their exception taxonomies — no Dio, no `dart:io`,
no browser APIs. `dio_network` implements these for mobile and desktop,
`web_network` for the browser; both depend on this package, and nothing here
depends on either. A consumer that codes against these types works unchanged
on every platform.

## Responsibilities

- **`WellKnownClient`** — fetches and parses `/.well-known/bge-identity`, the
  discovery document that identifies a BGE server and drives the login UI.
  The endpoint is unauthenticated and is called before any credentials exist,
  so implementations must not attach tokens or session cookies. Failures are
  split into `WellKnownUnreachableException` (network or timeout),
  `WellKnownNotFoundException` (404 — not a BGE server), and
  `WellKnownInvalidResponseException` (non-200 or unparseable body).
- **`HouseholdRemoteDataSource`** — the first domain REST client (#39):
  `POST /api/households`. Failures are wrapped as
  `HouseholdRemoteTransientException` (retryable — connection errors,
  timeouts, 401/408/429, 5xx, status-less) or
  `HouseholdRemotePermanentException` (400/403 and other 4xx, plus a 2xx
  carrying no parseable household), so callers never see a transport
  exception type.
- **`tryParseHttpDate`** — RFC 9110 §5.6.7 IMF-fixdate parsing for the `Date`
  header, used by the clock-skew sampling in `dio_network`.

## Boundaries

- Implementations run over a **per-server** authenticated transport. The
  injected client carries the base URL (path-prefix deployments included) and
  attaches the session the endpoints require; these interfaces add no auth
  handling of their own, which is why every documented path is relative.
- The failure taxonomies are part of the contract, not an implementation
  detail. An implementation that leaks a raw transport exception has broken
  it — the transient/permanent split is what the sync queue keys its retry
  decisions off.

Part of the Board Games Empire client monorepo; not published to pub.dev.
