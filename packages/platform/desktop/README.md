# desktop_platform

The desktop composition root for Board Games Empire.

A thin subclass of `NativePlatformBootstrap` (from `native_platform`), which
does the real work: opening the encrypted meta database, building the meta
repositories, composing the per-server `ServerContextFactory`, and
constructing and initializing the `ServerOrchestrator`. This package exists
as the hook point for desktop-specific concerns, and carries only what
genuinely differs today.

## Responsibilities

- **`DesktopPlatformBootstrap`** — the shared native composition, plus the
  rotating file log (#100). A self-hoster can tail that file or attach it to
  a bug report without going through the in-app feedback flow; mobile stays
  Logcat-only.

## Boundaries

- Desktop-specific work that has not landed yet belongs here when it does:
  window and tray management, deep-link registration (#10), and `BuildInfo`
  (#35). The orchestrator's longer desktop backgrounding timeout is *not* one
  of them — it already keys off runtime platform detection inside the
  orchestrator rather than off this bootstrap.
- Everything shared with mobile stays in `native_platform`. If a change would
  apply to both, it goes there, not here.

## Entry point

```dart
// apps/desktop/lib/main.dart
await runBgeApp(platformBootstrap: DesktopPlatformBootstrap());
```

Part of the Board Games Empire client monorepo; not published to pub.dev.
