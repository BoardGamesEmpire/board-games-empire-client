## Unreleased

* `WebActiveServerScope`: a constant single-value `ActiveServerScope` holding
  the serving origin's `ActiveServer`. `active` is always non-null and
  `watchActive()` replays it to each subscriber then stays open — the
  intentional "not a degenerate orchestrator" shape for the single-origin web
  model (no orchestrator, no server switching) (#96).
* `bootstrapWebServerScope`: the web composition entry point. Resolves the
  origin, fetches its `ServerIdentity` through the `WellKnownClient` seam
  (reusing `WellKnownClientImpl`), populates an isolated per-server container
  via `registerServerNetworkWeb`, and returns the single-origin scope with
  `serverId`/`displayName` sourced from the identity. Well-known failures
  propagate unchanged for the shell to surface as a retryable bootstrap
  failure (#96).

## 0.0.1

* TODO: Describe initial release.
