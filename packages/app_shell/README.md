# app_shell

The shared application shell for Board Games Empire: bootstrap sequencing,
routing, and the shell-level screens that every platform app renders through.

Apps (`apps/mobile`, `apps/desktop`, `apps/browser`) are thin `main.dart`
wrappers — they construct a platform `PlatformBootstrap` and hand it to
`runBgeApp`. Everything else (the state machine that drives startup, the
router, the splash/error/placeholder screens, breadcrumb capture) lives here
so behaviour is identical across platforms.

## Responsibilities

- **`runBgeApp`** — the single entry point for an app's `main()`. Initializes
  observability, the Flutter binding, and uncaught-error hooks, constructs the
  `AppBootstrapCubit`, starts (does not await) bootstrap, and calls `runApp`.
- **`AppBootstrapCubit` / `AppBootstrapState`** — the bootstrap state machine
  (`initializing → needsServer | needsAuth | failed`, plus `ready` fed later by
  the auth wiring). Owns the retry / confirmed-destructive-reset policy and
  hydrated-storage initialization.
- **`PlatformBootstrap`** — the contract each platform implements
  (`native_platform`, `web_platform`). Returns a `BootstrapResult`
  (`hasServer`, optional `orchestrator`) and exposes reset support.
- **Router (`buildAppRouter`)** — go_router table whose redirects are driven
  entirely by bootstrap state, plus the reserved deep-link path subtree
  (resolved to `NotYetAvailableScreen` until the features land).
- **Screens** — splash, bootstrap-error (retry + confirmed reset, a11y-aware),
  not-yet-available, and the server-add/auth/home placeholders.
- **`ShellObservability`** — attaches the process-wide `BreadcrumbBuffer` so
  startup failures are captured for feedback reports.

## Entry points

```dart
// apps/<platform>/lib/main.dart
Future<void> main() async {
  await runBgeApp(platformBootstrap: MobilePlatformBootstrap());
}
```

## Boundaries

- No platform-specific dependencies (no `dart:io`, no `path_provider`); those
  live in the platform packages behind `PlatformBootstrap`.
- `hydrated_bloc` here is bloc-state persistence only, not a data cache.

Part of the Board Games Empire client monorepo; not published to pub.dev.
