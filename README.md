# Board Games Empire — Client

Flutter client for Board Games Empire: a self-hosted board game collection and
household play tracker. You point the app at a BGE server you or someone you
trust runs, and it manages collections, households, and play history against it.
No third-party data sharing by default.

One codebase, three targets, built in parallel from day one:

| Target | Directory | Notes |
| --- | --- | --- |
| Android / iOS | [apps/mobile](apps/mobile) | Android is the primary alpha target |
| macOS / Linux / Windows | [apps/desktop](apps/desktop) | macOS is the alpha desktop target |
| Browser | [apps/browser](apps/browser) | Needs the dev proxy locally — see below |

> **Status: pre-alpha.** There is no installable release yet. The infrastructure
> layers (storage, network, auth, observability, sync queue) are in place and
> exercised by tests; the feature surface is still being built. See
> [docs/ROADMAP.md](docs/ROADMAP.md) for what's done and what's next.

## Quick start

Requires **Flutter 3.44.4 exactly** — the pin is deliberate and any other
version fails to resolve. See [CONTRIBUTING.md](CONTRIBUTING.md#prerequisites)
for why, and how to bump it.

```bash
dart pub global activate melos ^7.5.1   # match the pinned version, see CONTRIBUTING.md
flutter pub get
melos run generate               # required — generated code is gitignored
melos run test --no-select       # all 22 packages with tests
```

`melos run generate` is not optional on a fresh checkout. Generated sources
(`*.g.dart`, `*.freezed.dart`, and the gen-l10n localizations) are deliberately
never committed, so analysis and tests fail until they exist.

Then run a target:

```bash
melos run mobile           # connected device or emulator required
melos run desktop-macos    # or desktop-linux / desktop-windows
melos run web:server       # web dev server + the dev proxy together
```

The browser target must be opened through the proxy origin, not the Flutter dev
server port — the cookie-based auth model depends on it.
[docs/dev/web-proxy.md](docs/dev/web-proxy.md) explains the topology.

## Repository layout

A [pub workspace](https://dart.dev/tools/pub/workspaces) of 28 members — 25
packages plus the 3 apps — orchestrated with [melos](https://melos.invertase.dev).

```text
apps/{mobile,desktop,browser}   thin main.dart wrappers, 6-11 lines each
packages/
  app_shell                     bootstrap, routing, shell screens
  core/{models,interfaces,di,observability}
  features/{auth,feedback,household,server_onboarding}
  platform/{mobile,desktop,web,native_platform,connectivity_platform}
  storage/{drift_storage,web_storage,key_storage,memory_storage,storage_interface}
  network/{dio_network,web_network,network_interface}
  ui/{tokens,widgets}
  testing/l10n
tool/                           check_sdk_constraints.dart, dev_proxy/
docs/                           ROADMAP.md, dev/
```

The rule that matters: **apps are thin wrappers.** All three `main.dart` files
just construct a platform `PlatformBootstrap` and hand it to `runBgeApp`.
Everything with behaviour lives in `packages/app_shell` and below, so the three
targets cannot diverge. [packages/app_shell/README.md](packages/app_shell/README.md)
is the best single description of how startup works.

Platform differences are handled by paired implementations behind a shared
interface — `drift_storage` ↔ `web_storage`, `dio_network` ↔ `web_network` —
rather than by conditionals in feature code.

Two naming traps when writing imports:

- **Five directories don't match their package name**: `testing/l10n` is
  `l10n_test_support`, `ui/tokens` is `ui_tokens`, and `platform/{web,mobile,desktop}`
  are `web_platform`, `mobile_platform`, `desktop_platform`.
- **`packages/app_shell` sits directly under `packages/`**, not under a layer
  directory like everything else.

## Appearance

The app follows your OS light/dark setting, and you can override it in
Settings. It is **designed dark-first** — the palette ("storm over walnut") was
authored against the dark theme and the light theme derived from it, so dark
mode is where the app looks its best. The light and high-contrast themes are
fully supported and meet the same WCAG AA contrast bar; they are simply not
where the design started.

The OS "increase contrast" setting is honored automatically, as is OS text
scaling up to 200%.

See [docs/design/STYLE_GUIDE.md](docs/design/STYLE_GUIDE.md).

## Documentation

- [CONTRIBUTING.md](CONTRIBUTING.md) — toolchain pin, first run, the melos
  scripts, codegen ordering, goldens, and what CI gates
- [docs/ROADMAP.md](docs/ROADMAP.md) — architectural ground truth, phases,
  deferred decisions
- [docs/design/STYLE_GUIDE.md](docs/design/STYLE_GUIDE.md) — identity, tokens,
  the shared widget set, and the accessibility rules
- [docs/dev/web-proxy.md](docs/dev/web-proxy.md) — local web testing
- [SECURITY.md](SECURITY.md) — reporting a vulnerability

Most packages carry their own README; `app_shell`, `features/household`, and
`ui/tokens` are the most substantial.

## License

[Apache License 2.0](LICENSE).
