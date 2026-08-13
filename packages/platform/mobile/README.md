# mobile_platform

The mobile composition root for Board Games Empire.

A thin subclass of `NativePlatformBootstrap` (from `native_platform`), which
does the real work: opening the encrypted meta database, building the meta
repositories, composing the per-server `ServerContextFactory`, and
constructing and initializing the `ServerOrchestrator`. This package exists
as the hook point for mobile-specific concerns.

## Responsibilities

- **`MobilePlatformBootstrap`** — the shared native composition, unmodified
  for the alpha scope. Logging stays Logcat-only; the rotating file log is a
  desktop-only override.

## Boundaries

- Mobile-specific work that has not landed yet belongs here when it does:
  connectivity monitoring, device info for feedback reports, deep-link
  manifests (#10), and `BuildInfo` (#35).
- Everything shared with desktop stays in `native_platform`. If a change
  would apply to both, it goes there, not here — which is why this class is
  currently empty, and that is the intended state rather than an omission.

## Entry point

```dart
// apps/mobile/lib/main.dart
await runBgeApp(platformBootstrap: MobilePlatformBootstrap());
```

Part of the Board Games Empire client monorepo; not published to pub.dev.
