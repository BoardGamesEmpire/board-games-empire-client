# Contributing

This is a pre-alpha project under active development, and there is no formal
process yet. Issues and pull requests are welcome; the tracker holds the
detailed scopes and [docs/ROADMAP.md](docs/ROADMAP.md) holds the ordering.

Everything below is the operational knowledge you need to get a green checkout.

## Prerequisites

### Flutter 3.44.4 — exactly

The root [pubspec.yaml](pubspec.yaml) pins an exact Flutter version, not a range:

```yaml
environment:
  sdk: ^3.12.0
  flutter: 3.44.4
```

**This means `flutter pub get` fails on any other version, newer stables
included.** That is deliberate: CI installs the toolchain by reading this exact
value (`flutter-version-file: pubspec.yaml`), so a moving constraint would let
local and CI silently diverge. A resolve error here is the pin working, not a
bug — check `flutter --version` first.

Use [fvm](https://fvm.app) or your own version manager to keep 3.44.4 available.

### Bumping the toolchain

Every package repeats the constraint, so bumping is a two-step operation:

```bash
# 1. edit the root environment: block, then
dart run tool/check_sdk_constraints.dart --fix
```

`--fix` propagates the new values to all 28 workspace pubspecs and preserves the
comments in each `environment:` block. Then `flutter pub get` to re-resolve.

Never hand-edit the per-package constraints. The whole point of
[tool/check_sdk_constraints.dart](tool/check_sdk_constraints.dart) is that they
cannot drift: it enforces that every package's `sdk` matches the root verbatim,
that a package pulling from the Flutter SDK declares `flutter: ">=<root pin>"`,
and that one which does not declares no `flutter:` key at all. CI runs it on
every PR.

This exists because `flutter create` leaves `flutter: ">=3.0.0"` behind, and pub
can never fail on it — the Dart floor already excludes every Flutter that old, so
the constraint is inert. 17 packages had drifted that way before #153.

### melos

```bash
dart pub global activate melos ^7.5.1
```

**Pass the constraint.** A bare `dart pub global activate melos` installs the
current latest, which is 8.x — while the root declares `melos: ^7.5.1`. Melos 8
changed how `exec` scripts are configured, and this workspace has not been
migrated, so keep the globally activated CLI on the same major as the declared
dev dependency.

Configuration lives under the `melos:` key in the root `pubspec.yaml` — there is
no `melos.yaml`.

## First run

```bash
flutter pub get
melos run generate
melos run test --no-select
```

**`melos run generate` is required, not optional.** Generated code is gitignored
and never committed, so a fresh checkout has none of it and both analysis and
tests fail with unresolved symbols until it exists. That covers `*.g.dart`,
`*.freezed.dart`, and the gen-l10n localizations.

Generation is staged, and the order matters:

1. **`generate:i18n`** — `flutter gen-l10n` in each package owning an `l10n.yaml`
   (`app_shell` and the four `features/*` packages). These must exist first.
2. **`generate:build`** — one workspace-wide `build_runner` pass
   (`--workspace`), so the builders compile once rather than per package.

`melos run generate` runs both in order. `melos run clean:generated` deletes the
output if you need to start over.

## Scripts

Run `melos run` with no arguments to list everything. The ones worth knowing:

| Script | What it does |
| --- | --- |
| `generate` | Staged codegen — l10n, then build_runner. Required on a fresh checkout. |
| `analyze` | `flutter analyze` on Flutter packages |
| `analyze:dart` | `dart analyze --fatal-infos` on pure-Dart packages |
| `format` | `dart format` over every tracked `.dart` file |
| `format:check` | Fail if any tracked Dart source is unformatted. Mirrors CI. |
| `test` | All non-golden tests, 22 packages. Mirrors CI. |
| `test:goldens` | Golden tests only, against the committed baselines |
| `goldens:update` | Regenerate golden baselines after an intended visual change |
| `check:constraints` | Verify the workspace pubspec invariants |
| `check:palette` | Re-derive the palette and check its contrast and hue targets |
| `schema:dump` | Refresh the committed Drift schema snapshots |
| `web` / `web:proxy` / `web:server` | Web dev server, dev proxy, or both together |
| `mobile` / `desktop-macos` / `desktop-linux` / `desktop-windows` | Run an app |

Three scripts assume a POSIX shell and will not run under cmd or PowerShell:
`run-all` (job control, `case`, `uname`), `web:server` (`trap`, job control), and
`clean:generated` (`find`). On Windows, start the apps in separate terminals and
delete generated files by hand. Everything else is portable.

Any script with a `packageFilters:` block — `analyze`, `analyze:dart`, `test`,
`test:goldens`, `goldens:update` — prompts you to pick a package first. Press
Enter to take the default and run all of them. In a non-interactive shell that
prompt cannot be drawn and melos crashes on it, so scripts and CI need the flag:

```bash
melos run test --no-select
```

Melos classifies packages by dependency, not directory, which is why `analyze`
and `analyze:dart` are split: `flutter analyze` cannot run on a pure-Dart package
and `dart analyze` cannot resolve a Flutter one. A package that gains a Flutter
dependency moves between the two sets automatically.

Both analysis paths treat infos as fatal — `flutter analyze` does so by default,
and `analyze:dart` passes `--fatal-infos` to match. Silence a genuinely
acceptable diagnostic at the source with an `// ignore:` and a reason rather than
loosening the gate.

## Testing

Tests live in `test/` in each package; 22 of the 28 members have them. CI runs
one job per package so a failure names the package directly.

```bash
melos run test --no-select               # everything except goldens
cd packages/core/models && flutter test  # one package
```

### Goldens

Golden tests carry the `golden` tag and are excluded from `melos run test`, which
mirrors CI. Run them deliberately:

```bash
melos run test:goldens --no-select     # compare against committed baselines
melos run goldens:update --no-select   # rewrite baselines after an intended change
```

Only `test/**/goldens/ci/` is committed — Ahem-rendered and renderer-stable. The
per-host `goldens/<platform>/` output is gitignored, and the platform variant is
disabled in each package's `flutter_test_config.dart`; see the comment there for
why, and #159 for the open question of which host should own the baseline.

Commit only the `ci/` PNGs.

Both golden scripts filter on `dirExists: test/goldens`, so they run only in
packages that actually own baselines — `ui_tokens` and `ui`
(`packages/ui/widgets`) today. If you add goldens
to another package, put them under `test/goldens/` or the scripts will skip it —
and note that `flutter test --tags golden` exits 79 ("no tests ran") in a package
with no golden-tagged tests, which melos reports as a failure rather than a
no-op. That is why the filter is narrow.

### Drift schemas

After changing a Drift schema, refresh the committed snapshots and commit the
JSON:

```bash
melos run schema:dump
```

CI diffs the snapshots against a fresh dump and fails if they are stale.
`melos run schema:migrations` generates migration scaffolding.

## What CI gates

[.github/workflows/ci.yaml](.github/workflows/ci.yaml) runs on every PR and on
pushes to `master`, in seven jobs:

| Job | Gate |
| --- | --- |
| `constraints` | `check_sdk_constraints.dart --self-test`, then the real check |
| `palette` | `derive_palette.dart` re-derives the palette; every contrast target and the ember/error hue separation must hold |
| `format` | `dart format --set-exit-if-changed` over the workspace source |
| `generate` | Codegen succeeds; Drift schema snapshots are not stale. Publishes generated sources as an artifact the later jobs restore. |
| `analyze` | One root `dart analyze --fatal-infos .` across the workspace |
| `discover-tests` | Builds the test matrix by finding `test/` directories |
| `test` | One job per package, golden tags excluded |

CI deliberately does **not** use melos — it reimplements the equivalents inline
so a broken melos script cannot take the build down with it. If you change a
melos script that has a CI counterpart, change both.

## Conventions

- **No hardcoded user-facing strings.** Every user-visible string comes from an
  ARB-backed localizations class, and template keys need an `@key` description —
  the coverage test hard-fails without one.
- **No literal colors, spacing, type, or radii at call sites.** All of them
  come from `ui_tokens` — use `const BgeGap.md()` for spacing,
  `Theme.of(context).colorScheme` for color, `Theme.of(context).textTheme` for
  type. This is enforced by
  `packages/ui/tokens/test/design_system_enforcement_test.dart` (it runs in
  `melos run test`), not by review. See
  [docs/design/STYLE_GUIDE.md](docs/design/STYLE_GUIDE.md) for the rules and
  [packages/ui/tokens/README.md](packages/ui/tokens/README.md) for the contrast
  guarantees.

  The heading used to say "no literal **colors**" while the body listed spacing
  too (#165). It means all of them.
- **Apps stay thin.** Behaviour belongs in `app_shell` or a feature package, not
  in `apps/*/lib/main.dart`.
- **Platform differences go behind an interface**, as paired implementations
  (`drift_storage` ↔ `web_storage`), not conditionals in feature code.
- Analysis uses [very_good_analysis](https://pub.dev/packages/very_good_analysis).

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org)
(`fix(tool):`, `chore(pubspec):`, `feat(auth):`), and reference the issue they
close.
