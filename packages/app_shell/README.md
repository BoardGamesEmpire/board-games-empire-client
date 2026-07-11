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

## Internationalization (#33)

The shell owns app-level i18n composition; features contribute to it. The
conventions:

- **No hardcoded user-facing strings.** Every string a user can see comes
  from an ARB-backed localizations class (`ShellLocalizations` here,
  `AuthLocalizations` in the auth feature, one per l10n-owning package).
  Template keys **must** carry an `@key` `description` — the coverage test
  hard-fails without one.
- **Delegate contribution.** The shell registers its own
  `ShellLocalizations.localizationsDelegates` (which bundle the three
  `Global*` delegates) plus whatever `additionalLocalizationsDelegates`
  receives. Feature packages contribute **only their single**
  `XxxLocalizations.delegate` through that seam — never their bundled
  `.localizationsDelegates` list, which would re-include the `Global*`
  delegates. Auth's delegate is wired by #37.
- **Locale resolution & fallback.** `supportedLocales` is
  `ShellLocalizations.supportedLocales` with `en` first. There is **no
  custom `localeResolutionCallback`** — Flutter's default chain (exact
  match → languageCode match → first supported locale) provides the `en`
  fallback for free and stays correct as locales are added. A user-selected
  locale override is #78, the first thing that would need a callback.
- **Active locale (`ActiveLocaleReader` / `ActiveLocaleController`).**
  Non-widget consumers (feedback environment stamps, gateway `locale` hints)
  need the **negotiated** locale, not the raw OS preference. `runBgeApp`
  seeds a controller with the OS locale, registers it app-scope in the root
  container (resolve-or-default — a pre-registered reader stays
  authoritative), and `BgeApp` mirrors the resolved locale into it below
  `Localizations` on every locale change.
- **Generated code is gitignored + regenerated.** `lib/l10n/*_localizations*.dart`
  and `lib/l10n/untranslated.txt` are never committed. `melos run generate`
  is staged: `generate:l10n` (a `flutter gen-l10n` run in every package
  owning an `l10n.yaml`) **then** `generate:build` (one workspace-wide
  build_runner pass). A fresh checkout must run `melos run generate` once
  before analyze/test; CI mirrors the same staging in its `generate` job.
- **Partial coverage is allowed.** gen-l10n inherits missing messages from
  the template, so a new language needn't land with a complete key set.
  Gaps stay visible via `untranslated-messages-file` and the per-package
  coverage test (`l10n_test_support`), which hard-fails only on missing
  template descriptions, orphan keys, and `@@locale`/filename mismatches.

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
