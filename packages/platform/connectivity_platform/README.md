# connectivity_platform

Shared device connectivity awareness for Board Games Empire.

Provides `ConnectivityPlusService`, the concrete implementation of the
`ConnectivityService` contract from `interfaces`, backed by the
`connectivity_plus` plugin.

Unlike `BuildInfoReader` — which is split into native and web twins to keep
platform dependencies out of the wrong build — this package is **shared** by
both the native and web composition roots. `connectivity_plus` is a federated
plugin (js_interop on web), so a single package resolves to the right
platform implementation at build time without dependency bleed.

## Behaviour

- **Optimistic seed.** `current` is `online` immediately at construction, then
  an eager `checkConnectivity()` corrects it to the true state a moment later.
  A change event arriving before the check wins; a stale check result is
  discarded. A failing check is swallowed and the seed stands.
- **Coarse mapping.** A list containing any non-`none` transport is `online`;
  `[none]`-only or an empty list is `offline`. `ConnectivityState.unknown` is
  reserved for forward-compat and is never emitted by this implementation.
- **Replay + dedupe.** `watch()` replays the current state to every new
  subscriber (seeded `BehaviorSubject`) and then emits on each coarse-state
  change; consecutive duplicate states (e.g. wifi → ethernet) are suppressed.

## Lifecycle

`ConnectivityPlusService` implements the container's `Disposable` marker.
`dispose()` cancels the platform subscription and closes the stream; it is
idempotent, and `current` remains readable afterwards. Both root modules
register the service **lazily** (the constructor touches the plugin) with a
dispose callback, so container teardown drives cleanup.

## Testing

The constructor exposes two injectable seams — `connectivityChanges` and
`connectivityCheck` — so the full contract is driven with synthetic events;
`connectivity_plus` itself is never mocked. See
`test/connectivity_plus_service_test.dart`.

Part of the Board Games Empire client monorepo; not published to pub.dev.
