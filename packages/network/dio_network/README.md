# dio_network

The shared Dio layer under the `network_interface` contracts: the
`DioFactory` seam, the redaction-safe log and clock-skew interceptors, and the
Dio-backed remote data sources and clients. Both the native stack
(`native_network`) and the browser stack (`web_network`) build on it, so it
carries no token custody and no `flutter_secure_storage`.

Bearer-token custody, `AuthRepositoryImpl` and the per-server composition root
live in `native_network`.

## Contents

- **`network/`** — `DioFactory` and the interceptors (redaction-safe request
  logging, clock-skew sampling), plus `redactUri`.
- **`feedback/`** — `FeedbackDioTransport`, the authenticated feedback sender.
- **`household/`** — `HouseholdRemoteDataSourceImpl` (see below).
- **`well_known/`** — `WellKnownClientImpl`. The one client that builds its
  own auth-free `Dio`, because the discovery endpoint is unauthenticated and
  is called before a server scope exists.

## HouseholdRemoteDataSourceImpl

Implements `HouseholdRemoteDataSource` (#39): `POST /api/households`, unwrapping
the `{ message, household }` envelope into a domain `Household`.

- Takes the **injected** per-server `Dio` — the base URL (path-prefix
  deployments included) and the BetterAuth session come from that stack, so
  the path is relative and the class adds no auth of its own.
- Maps response fields explicitly rather than via `Household.fromJson`,
  keeping the wire representation decoupled from the persistence
  representation; the client-only sync flags default to `false` on a
  server-confirmed row.
- Classifies every failure as `HouseholdRemoteTransientException`
  (retryable: connection errors, timeouts, 401/408/429, 5xx, status-less) or
  `HouseholdRemotePermanentException` (400/403 and other 4xx, plus a 2xx whose
  body carries no parseable household). Callers never see a raw
  `DioException`.

The feature-level flow that consumes this (optimistic write, queued sync op,
reconcile) is documented in `packages/features/household/README.md`.
