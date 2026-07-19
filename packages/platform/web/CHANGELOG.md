## Unreleased

* `WebPlatformBootstrap.initialize` now fetches the origin identity and returns
  the single-origin `ActiveServerScope` in its `BootstrapResult`, lighting up
  the shared shell's auth subtree on web. Added an injectable
  `serverScopeBuilder` seam (defaults to `bootstrapWebServerScope`); the const
  production constructor is preserved. A well-known fetch failure propagates as
  the shared retryable bootstrap-failure state — web never routes to a "needs
  server" state (#96).
* Depend on `web_network` for the cookie-based network stack and origin
  well-known fetch (#96).

## 0.0.1

Initial internal release (#31).

* `WebPlatformBootstrap` implementing the `PlatformBootstrap` contract for the
  single-origin web model: server present by construction, no orchestrator,
  reset unsupported, web-backed hydrated storage.
* `configureWebUrlStrategy` for path-based (fragment-free) browser URLs.
