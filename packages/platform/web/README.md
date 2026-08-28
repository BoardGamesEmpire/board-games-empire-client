# web_platform

The web composition root for Board Games Empire.

Implements the `PlatformBootstrap` contract from `app_shell` for the browser,
where the constraints differ fundamentally from native: the app can only talk
to the origin in the address bar, so a server is present by construction,
there is no meta database, no server switching, and no orchestration.

## Responsibilities

- **`WebPlatformBootstrap`** — returns a `BootstrapResult` with
  `hasServer: true` and no orchestrator; auth is cookie-owned via
  `web_network` and wired separately. Reset is unsupported (there is no
  device-local meta database to delete) and `hydratedStorageDirectory`
  resolves to the web backend.
- **`configureWebUrlStrategy`** — installs path-based URLs (no `#` fragments)
  so the reserved deep-link paths are real browser URLs. Call first in the
  browser app's `main()`, before `runBgeApp`.

## Two entry points

`web.dart` is platform-neutral in the same sense as `drift_storage.dart`
(#287): everything reachable from it compiles for the VM, which is what keeps
this package's own suites — widget tests included — in the normal test matrix.

`web_storage_composition.dart` is the browser-only half (#288): it composes
`web_storage`'s drift/wasm executor into the server scope and exposes
`bgeWebPlatformBootstrap()`, which is what the browser app's `main()` uses.
It is browser-only because `package:drift/wasm.dart` reaches
`dart:js_interop`; exporting it from `web.dart` would make every consumer of
this package browser-only.

## Boundaries

- The data layer is composed here, not in `web_network`: that package assembles
  the server scope but must not depend on a browser-only library, so it takes a
  `WebServerScopeInstall` seam instead (#288 D3).
- No at-rest encryption on web (#63 D3) — the browser origin sandbox is the
  security boundary. The reasoning lives on `WebWasmExecutorFactory`.
- The per-user session scope (repositories keyed to the signed-in user) is
  **not** here yet: that is #137, over #289's scope primitive. This package
  registers the `ServerDatabase` those repositories will be built on.

## Entry point

```dart
// apps/browser/lib/main.dart
Future<void> main() async {
  configureWebUrlStrategy();
  await runBgeApp(platformBootstrap: bgeWebPlatformBootstrap());
}
```

`const WebPlatformBootstrap()` also boots — without a database. The composed
factory has its own name so that mistake has to be made deliberately.

Part of the Board Games Empire client monorepo; not published to pub.dev.
