# ui_tokens

Design-system token layer for Board Games Empire (#32): the single source of
truth for color, typography scale, spacing, density, motion, and the
theme-level accessibility baseline. Consumed via `Theme.of(context)` — the
app shell installs `BgeTheme` as the `MaterialApp` default.

## Conventions (project-wide)

- **No literal colors at call sites.** Reference `Theme.of(context).colorScheme`
  and `Theme.of(context).extension<BgeTokens>()!`. This is the token contract
  the future SDUI/plugin layer (#19) leans on.
- **No information conveyed by color alone.** Pair color with an icon, text,
  or shape change. This — plus verified AA contrast and the high-contrast
  themes — is the project's answer to color-vision deficiency (confirmed
  decision: no per-CVD palettes).
- **System typeface.** Tokens define the type *scale* (`BgeTypography`), not
  a family — zero font assets, zero network fetches (offline/privacy-first).
- **OS accessibility signals are honored automatically.** High-contrast
  themes ride `MediaQuery.highContrast`; reduced motion rides
  `MediaQuery.disableAnimations` via `BgeMotion`; OS text scaling is honored
  up to `BgeTextScale.maxScaleFactor` (200%, the WCAG 1.4.4 target).

## Contrast guarantees

Every authored on-role/role pair is test-enforced: ≥ 4.5:1 (WCAG 2.1 AA,
normal text) in light/dark, ≥ 7.0:1 in the high-contrast variants. Do not
edit `BgeColorSchemes` without keeping `bge_color_schemes_test.dart` green.

## Goldens

Alchemist. Regenerate with `flutter test --update-goldens`; only
`test/**/goldens/ci/` is committed (renderer-stable Ahem rendering).
Run `flutter test --exclude-tags golden` to skip them.
