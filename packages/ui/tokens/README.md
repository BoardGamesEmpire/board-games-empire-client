# ui_tokens

Design-system token layer for Board Games Empire (#32): the single source of
truth for color, typography scale, spacing, density, motion, and the
theme-level accessibility baseline. Consumed via `Theme.of(context)` — the
app shell installs `BgeTheme` as the `MaterialApp` default.

See [`docs/design/STYLE_GUIDE.md`](../../../docs/design/STYLE_GUIDE.md) for
what the app should look like and why; this README covers the package API.

## Conventions (project-wide)

- **No literal colors, spacing, radii or type at call sites.** Reference
  `Theme.of(context).colorScheme`, `Theme.of(context).textTheme`, and
  `BgeTokens.of(context)` — **not** `extension<BgeTokens>()!`, which throws
  wherever no `BgeTheme` is installed (every feature widget test pumps a bare
  `MaterialApp`). `BgeTokens.of` falls back to `BgeTokens.standard`, the same
  values every theme installs. For gaps, prefer `const BgeGap.md()`.

  This is enforced by `test/design_system_enforcement_test.dart`, which runs
  in `melos run test` — the rule was documented and unenforced for a long
  time, and repo-wide adherence was zero (#165). It is also the token
  contract the future SDUI/plugin layer (#19) leans on.
- **No information conveyed by color alone.** Pair color with an icon, text,
  or shape change. This — plus verified AA contrast and the high-contrast
  themes — is the project's answer to color-vision deficiency (confirmed
  decision: no per-CVD palettes).
- **Two typefaces, split by role.** Display, headline and title render in
  the bundled **Fraunces** (SIL OFL, variable, ~360KB, `fonts/`); body and
  label stay on the platform face. This amends #32's original "zero font
  assets" decision — the font ships in the binary, so there is still **zero
  network fetch and no third party**; the cost is size, not privacy.

  Every variable axis must be set explicitly. Fraunces' own defaults are
  `opsz=9, wght=900, WONK=1`, so an unset axis is not neutral — it silently
  renders small-text letterforms at display sizes. See `BgeTypography`.
- **OS accessibility signals are honored automatically.** High-contrast
  themes ride `MediaQuery.highContrast`; reduced motion rides
  `MediaQuery.disableAnimations` via `BgeMotion`; OS text scaling is honored
  up to `BgeTextScale.maxScaleFactor` (200%, the WCAG 1.4.4 target).

## Contrast guarantees

Every authored on-role/role pair is test-enforced: ≥ 4.5:1 (WCAG 2.1 AA,
normal text) in light/dark, ≥ 7.0:1 in the high-contrast variants. Body text
is also checked against **every** member of the surface family, not just
`surface` — text sits on containers too.

`tertiary` (ember) and `error` (crimson) are additionally held ~54° apart in
OKLCH hue (`Oklch.minAccentSeparation`). Contrast answers "can this be
read?", never "can these be told apart?", and these two are the palette's one
genuinely confusable pair.

That floor, the OKLCH hue transform and the sRGB transfer function are
defined once in `lib/palette_math.dart` — a Flutter-free second entry point,
outside the barrel, so `tool/derive_palette.dart` can check the palette
against the same numbers `Oklch` exposes to the app. Change them there.

`BgeColorSchemes` is **generated** — do not hand-edit it. Change the hues or
targets in `tool/derive_palette.dart` and regenerate:

```bash
dart tool/derive_palette.dart          # verify; exits 1 if any check fails
dart -Demit=true tool/derive_palette.dart \
  > packages/ui/tokens/lib/src/bge_color_schemes.dart
```

Both need a resolved workspace (`melos bootstrap`). Emit verifies first and
writes nothing if a check fails, so the second command does not need the
first — run it to read the report. Note that the shell truncates the target
before the script starts, so a failed emit leaves it empty; `git checkout`
puts it back.

Verification covers every authored pair, the accents against `surface`, body
text against the whole surface family, and the ember/error hue separation —
and sets an exit code, so it is safe to chain or run from a script. CI runs
it on every PR (`melos run check:palette` locally).

Then keep `bge_color_schemes_test.dart` green and refresh the goldens.

## Goldens

Alchemist. Regenerate with `flutter test --update-goldens`; only
`test/**/goldens/ci/` is committed (renderer-stable Ahem rendering).
Run `flutter test --exclude-tags golden` to skip them.
