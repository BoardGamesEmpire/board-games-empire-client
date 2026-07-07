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

## Boundaries

- Storage-less for the alpha: the web data layer (drift/wasm via `web_storage`,
  encryption posture, sync-queue role) is designed separately and re-adds its
  dependency here when it lands.

## Entry point

```dart
// apps/browser/lib/main.dart
Future<void> main() async {
  configureWebUrlStrategy();
  await runBgeApp(platformBootstrap: const WebPlatformBootstrap());
}
```

Part of the Board Games Empire client monorepo; not published to pub.dev.
