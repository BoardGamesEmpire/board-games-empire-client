# dio_network

The Dio-backed implementation of the `network_interface` contracts, for
mobile and desktop. Web uses its own stack (`web_network`); nothing here
may be imported from a web build.

## Composition root

`registerServerNetwork({container, config})` is the one place that knows how
the pieces fit together. It builds the **per-server** stack and registers it
into that server's DI container:

```
TokenStorageService -> TokenInterceptor -> DioFactory -> shared Dio
                                                      -> AuthRepository
                                                      -> FeedbackTransport
                                                      -> HouseholdRemoteDataSource
```

The `Dio` is registered as a shared per-server singleton so every repository
and data source resolves the same instance and inherits the interceptor stack
— including token attachment — with no construction-order dependency. The
container owns the `Dio` and closes it on dispose; individual clients must not
close a `Dio` they share.

Interceptor order (see `register_server_network.dart` for the reasoning):
`NetworkLogInterceptor` → `TokenInterceptor` → `ClockSkewInterceptor`.

## Contents

- **`network/`** — `DioFactory`, `registerServerNetwork`,
  `NetworkScopeInstaller`, and the interceptors (token attachment,
  redaction-safe request logging, clock-skew sampling).
- **`auth/`** — `AuthRepositoryImpl` (BetterAuth over the per-server Dio) and
  `TokenStorageService` (keyed by the stable `bgeServerId`).
- **`feedback/`** — `FeedbackDioTransport`, the authenticated feedback sender.
- **`household/`** — `HouseholdRemoteDataSourceImpl` (see below).
- **`well_known/`** — `WellKnownClientImpl`. The one client that builds its
  own auth-free `Dio`, because the discovery endpoint is unauthenticated and
  is called before a server scope exists.

## HouseholdRemoteDataSourceImpl

Implements `HouseholdRemoteDataSource` (#39): `POST /households`, unwrapping
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
