## 0.0.1

Initial internal release (#31).

* `WebPlatformBootstrap` implementing the `PlatformBootstrap` contract for the
  single-origin web model: server present by construction, no orchestrator,
  reset unsupported, web-backed hydrated storage.
* `configureWebUrlStrategy` for path-based (fragment-free) browser URLs.
