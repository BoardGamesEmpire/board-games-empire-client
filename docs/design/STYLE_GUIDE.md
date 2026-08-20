# Board Games Empire — Style Guide

The visual and interaction rules for the client. Companion to
[`packages/ui/tokens/README.md`](../../packages/ui/tokens/README.md) (which
documents the token package's API) — this document covers *what the app should
look like and why*.

> **The one rule that matters:** no literal colors, spacing, radii, or type
> sizes at call sites. Everything comes from a token. This is enforced by
> `packages/ui/tokens/test/design_system_enforcement_test.dart`, which runs in
> `melos run test` — not by reviewer vigilance, because that was tried and
> adherence reached zero (#165).

---

## 1. Identity — "storm over walnut"

Dark, warm, and electric. The surfaces are walnut in shadow — the table the
games sit on. The accents are the storm above it: an electric blue strike, a
violet cast, and a rare ember.

**Dark is the reference.** The palette was authored dark-first and light is
derived to match it. This is the opposite of the placeholder palette it
replaced, and it is why dark mode is the mode the app looks best in.

### Roles and their discipline

| Role | Hue | Use it for | Never |
| --- | --- | --- | --- |
| `primary` | Electric blue | Primary actions, focus, links, the active state | Decoration |
| `secondary` | Storm violet | Supporting components, chips, low-emphasis containers | Anything urgent |
| `tertiary` | Ember | **Rare** high-attention accents — badges, "new", "pending" | Warnings that are really errors |
| `error` | Crimson | Failures the user must act on | Emphasis |

Ember is `tertiary` rather than `secondary` **on purpose**: M3 treats tertiary
as the rare contrasting accent, so keeping ember there keeps it sparse, and
sparse is what keeps it from being confused with `error`.

### The one weak point, and its three defenses

Ember and crimson are both warm and both mid-luminance. The first draft of this
palette had them 43° apart in OKLCH hue and they read as the same color at a
glance. Three things guard it now:

1. **Hue separation.** They sit ~54° apart, asserted by
   `bge_color_schemes_test.dart` against `Oklch.minAccentSeparation`.
2. **Scarcity.** Ember is the tertiary role, so it appears rarely.
3. **The icon rule** (below), which is the only one that helps a user with a
   color-vision deficiency.

### Never convey meaning by color alone

Pair every color-carried meaning with an icon, text, or a shape change. This
is the project's answer to color-vision deficiency — there are no per-CVD
palettes, by decision. `BgeStatusColors.iconFor` exists so the pairing is
easier to do than to skip.

A coloured dot is **not** a status indicator here.

### How the palette is produced

`BgeColorSchemes` is **generated**, not hand-picked. `tool/derive_palette.dart`
fixes each role's OKLCH hue and chroma — those carry the identity — and solves
its lightness numerically for an exact contrast target.

```bash
dart tool/derive_palette.dart          # verify, print the report
dart -Demit=true tool/derive_palette.dart \
  > packages/ui/tokens/lib/src/bge_color_schemes.dart
```

Both need a resolved workspace; emit verifies first and writes nothing if a
check fails. CI runs the first form on every PR. The hue threshold it checks
is the one `Oklch` exposes — both read
`packages/ui/tokens/lib/palette_math.dart`.

Two things about that script are easy to get wrong later:

- **Accents target barely above the 4.5:1 floor deliberately.** Raising the
  target to "improve" contrast pushes them lighter, which desaturates them, and
  the electric blue stops being electric.
- **`onSurface` is solved against the hardest member of the surface family**,
  not against `surface`. Text sits on containers too. Solving against the bare
  surface leaves the top containers failing while the authored-pair test still
  reports green — which is exactly what happened on the first pass.

---

## 2. Typography — two families

| Roles | Family | Why |
| --- | --- | --- |
| display, headline, title | **Fraunces** (bundled, variable, OFL) | Carries the identity. A UI built entirely from the system face reads as anonymous and looks different on each of the three platforms. |
| body, label | **Platform face** (SF, Roboto, Segoe) | Carries the *reading*. Hinted for the platform, ships glyphs for every locale the OS supports, and is what the user's accessibility settings were tuned around. |

This **amends** #32's original "zero font assets" decision. The privacy
reasoning behind it is untouched: the font is bundled in the binary, so there is
no network fetch and no third party. The cost is ~360KB of binary size. The
"never fetch a font at runtime" half of that decision still holds absolutely.

### Every variable axis must be set explicitly

Fraunces' own `fvar` defaults are **opsz=9, wght=900, WONK=1** — small-text
letterforms, black weight, wonky alternates on. An unspecified axis is not
neutral; it silently takes those, and nothing errors. `BgeTypography` pins all
four, and `bge_theme_test.dart` asserts it.

- **`wght`** from the axis, not `TextStyle.fontWeight` — synthetic bolding of a
  variable font is inconsistent across platforms.
- **`opsz`** from `BgeTypography.opticalSizeFor(size)`. This is the reason a
  variable serif is worth bundling at all: the same family draws a 57px title
  and a 14px label as genuinely different shapes rather than one outline scaled.
  Left at its default, a display heading renders in letterforms drawn for 9pt
  body copy.

Every role carries a **line height and tracking**, not just a size. Tracking
goes negative at display sizes (large serif text set at default tracking reads
as gappy) and positive at label sizes (small text needs air).

**Monospace** is available via `BgeTypography.monospaceFamily` for content whose
alignment carries information — stack traces, IDs meant to be compared. Apply it
as an override on a scale role, never as a whole style.

---

## 3. Spacing, shape, layout

The scale is `4 / 8 / 16 / 24 / 32 / 48`. **There is no 12** — that was decided
in #165 and the two call sites that wanted one were snapped to 8.

| Step | Token | Use |
| --- | --- | --- |
| 4 | `spaceXs` | Label to its own helper text |
| 8 | `spaceSm` | **Intra**-control: spinner to label, icon to text |
| 16 | `spaceMd` | **Inter**-control: field to field |
| 24 | `spaceLg` | Section break: last field to submit |
| 32 / 48 | `spaceXl` / `spaceXxl` | Major separation |

The 8-beside-16 relationship is the point: an 8dp gap inside a control next to a
16dp gap between controls reads as deliberate hierarchy.

### Writing spacing

```dart
const BgeGap.md()                        // vertical, in a Column
const BgeGap.sm(axis: Axis.horizontal)   // horizontal, in a Row
BgeTokens.of(context).spaceLg            // when you need the number
```

`BgeGap` is shorter to type than the literal it replaces. That is not a
coincidence — a rule whose correct form is longer than the wrong one loses to
whoever is trying to finish a screen.

`BgeTokens.of(context)` falls back to `BgeTokens.standard` when no theme
provides the extension, so a widget test pumping a bare `MaterialApp` works
without a tokenized harness.

### Layout

- `contentMaxWidth` (480) — the reading measure, for forms and prose. Applied
  by `BgePage` as its default. Desktop and browser are first-class targets; an
  unconstrained form stretches across a 27" monitor and puts a label a forearm
  from its input.
- `paneMaxWidth` (840) — the list/pane measure, via
  `BgePage(width: BgePageWidth.pane)`. A settings row is a label plus a
  trailing control, not a line of prose, so it reads badly squeezed to 480 —
  but it is still capped, because nothing stretches to the monitor.
- `breakpointMedium` (600) / `breakpointExpanded` (840).

**Measures are caps; breakpoints are thresholds.** A cap is already adaptive —
below it the content simply fills the window, so the same widget fits a phone
and stops short on a monitor with no window-class check. Reach for a breakpoint
only when a layout should *change form* (rail vs. bottom bar, one pane vs.
two), never to pick a width. `paneMaxWidth` and `breakpointExpanded` share a
value today and are still separate tokens: retuning one must not silently move
the other. Nothing consumes the breakpoints yet — that is #207.

---

## 4. Widgets

Use these. They exist because the hand-rolled versions drifted.

| Widget | Replaces | The thing it guarantees |
| --- | --- | --- |
| `BgePage` | the hand-rolled Scaffold→SafeArea→Center→Scroll→ConstrainedBox block in all 12 page screens | Always scrollable (content that fits at 1.0 does not at 200% text scale), always width-constrained; `footer:` pins an action below the scroll at the same measure |
| `BgeSubmitButton` | all 6 hand-rolled in-flight buttons | Cannot overflow (#163); disabled-not-hidden; keeps its accessible name; announces via live region |
| `BgeInlineBanner` | 3 divergent error banners | Tone → color *and* icon; announces on appearance **and scrolls itself into view**; one semantics node |
| `BgeTextField` | 3 divergent field implementations | Visible label; live-region error announcement; 48dp password toggle; theme border |

### In-flight forms

One rule, app-wide: while a submission is in flight, fields go **`readOnly`,
never `enabled: false`**. A disabled field leaves the focus order, so a
keyboard or screen-reader user mid-form has the control vanish underneath them
for the duration of a network call. Read-only keeps it present and readable and
still closes the keyboard submit path. `BgeTextField` deliberately exposes no
`enabled` so two screens cannot make opposite choices about the same moment.

The in-flight signal is carried by `BgeSubmitButton` — label swap plus spinner,
in a live region — not by greying the form out.

### Error and outcome surfaces

Three screens once answered this three different ways, on contradictory
assumptions about what a SnackBar announces (#191). One rule now, and the
question it turns on is **does the screen survive the outcome?**

| Situation | Surface |
| --- | --- |
| Outcome on a screen that stays | `BgeInlineBanner` (`announce: true`) |
| Outcome whose screen pops, or a notice belonging to no screen | bare `SnackBar` |

A state change with no outcome copy — a mode switch, a filter applied — is not
on this table. It takes a **live region on the text that changed**, per the
accessibility rules below; it does not take a `SemanticsService` announcement.

The discriminator is survival, not form-ness. `CreateHouseholdScreen` shows
both rows: success pops the screen, so its confirmation must outlive the route
and is a SnackBar owned by the `ScaffoldMessenger` above it; failure stays put,
so it is a banner on the screen. Splitting them by "is it a form outcome?"
would have put an inline banner on a screen that is about to be destroyed.

**A banner has to be retired; a SnackBar retires itself.** This is the half
that is easy to miss on the way from one surface to the other. A SnackBar
fades after a few seconds, so nothing has to remember to remove it. A banner
is bound to state and stays until that state changes — so the bloc needs a
`FailureCleared` event, and the screen has to send it when the failure stops
describing anything the user can still see: they edited the field it
complains about, or they switched to a different form. Skip this and the user
reads a complaint about the value they just replaced, or a sign-in error
pinned above the registration form. `ServerOnboardingFailureCleared` is the
reference; auth and create-household follow it.

**An announced banner still has to be seen.** `BgeInlineBanner` is a live
region, so assistive tech reads it on appearance — which is exactly why a
banner outside the viewport used to survive review. A sighted user who had
scrolled down to reach the submit button got a button that appeared to do
nothing (#209). The banner now reveals itself on appearance, and again whenever
its copy changes, so no call site re-decides it: it leads with **its own top
edge**, landing one spacing step below the viewport start rather than flush
against it — `BgePage` keeps its content inset inside the scroll view, so a
flush reveal scrolls that inset away and the banner ends up against the app
bar, reading as clipped. Three consequences worth knowing:

- **The top edge, not the whole banner.** At 200% text scale a single error
  string can be taller than the viewport — measured, `serverAddErrorClientTooNew`
  is 816dp against a 480dp one. Centring the reveal would show the middle of a
  wrapped sentence. (That the banner can be that tall at all is #228.)
- **Pass `reveal: false` for a *persistent* banner** — an offline indicator is
  furniture, not news, and one that scrolls itself into view on every mount
  fights a restored scroll position. A banner built **lazily inside a list**
  needs no flag: a row is never treated as an arriving outcome, because a
  forgotten flag there would make the list unusable rather than merely
  unhelpful.
- **It needs a vertical scroll view to work.** Unlike `announce`, which always
  annotates the semantics node, reveal acts on the nearest enclosing vertical
  scroll view and is a silent no-op without one — it does not walk outward
  through nested ones. A screen that hosts a banner outside a scroll view, or
  inside a nested one, keeps it in view itself. `BgePage` supplies exactly one,
  which is why every current call site gets this for free.

Reveal is opt-out for the same reason `announce` is: an accessibility guarantee
that each call site has to remember is one that some call site will forget.

**Never wrap a SnackBar in `Semantics(liveRegion: true)`.** Flutter already
does — `snack_bar.dart` wraps every SnackBar in
`Semantics(container: true, liveRegion: true)`, unconditionally, with no
opt-out. Adding another nests a live region inside a live region, which makes
assistive tech announce twice; the same stutter `BgeTextField` documents. This
was verified in the SDK, not assumed — the two screens that disagreed about it
could not both be right.

**Fields that are not prose** — URLs, hostnames, emails, IDs, codes — must set
`autocorrect: false` and `enableSuggestions: false`. An autocorrected server
address fails in a way the user cannot diagnose, because the field still shows
what they think they typed.

**Adding a widget to `ui`:** wait until a second call site wants it. The package
previously carried ~30 speculative dependencies (rive, lottie, fl_chart…) for
widgets that were never built, and every feature package would have pulled them
into all three app binaries.

---

## 5. Accessibility — non-negotiable

These are not aspirations; each is enforced somewhere.

- **48dp minimum tap target** (`minTapTarget`, WCAG 2.5.5). Theme-wide via
  `MaterialTapTargetSize.padded`, on desktop too — pointer precision does not
  remove the motor-accessibility need.
- **AA contrast** on every authored pair (4.5:1; 7:1 in high contrast), and on
  body text against **every** surface-family role.
- **200% text scale** (`BgeTextScale.maxScaleFactor`, WCAG 1.4.4). Test new
  screens at 320dp × 2.0 — that combination is where layouts break, and it is
  the user the feature was for.
- **Reduced motion** — resolve every duration through `BgeMotion.durationOf`.
  Easing comes from `BgeMotion.enter` / `.exit` / `.standard` / `.emphasized`;
  a duration alone does not describe a motion, and the same 300ms reads as
  mechanical on a linear curve and deliberate on a decelerating one.
- **Visible focus** — `focusOutlineWidth`, never removed.
- **No meaning by color alone.**
- **Live regions, not `SemanticsService.announce`** — announcement events are
  deprecated on Android because they force TalkBack to clear its speech queue.
- **Disable, don't hide**, in-flight controls, and keep their accessible name. A
  control that vanishes mid-interaction moves focus and loses the user's place.

---

## 6. Theming and customization

`BgeTheme` builds from a `BgePalette`. `BgePalette.storm` is the only one today
and is the default everywhere.

```dart
BgeTheme.light()              // cached; the shell resolves this every build
BgeTheme.from(myPalette)      // NOT cached — hold the result
```

The caching distinction is load-bearing: the shell resolves
`widget.theme ?? BgeTheme.light()` on every `BgeApp` rebuild, and a fresh
`ThemeData` per build would hand `MaterialApp` a new theme identity each time
and repropagate `Theme` to the whole subtree.

Any new palette must clear the same bar the default does — AA/AAA contrast on
authored pairs, `Oklch.minAccentSeparation` between tertiary and error, and
legible body text on every surface role.

---

## 7. Checklist for a new screen

- [ ] Built on `BgePage` — `width: BgePageWidth.pane` for a list surface, the
      default form measure otherwise; `footer:` for a pinned action
- [ ] Spacing from `BgeGap` / `BgeTokens`; no literals
- [ ] Colors from `Theme.of(context).colorScheme`; no `Colors.*`
- [ ] Type from `Theme.of(context).textTheme`
- [ ] Forms use `BgeTextField` + `BgeSubmitButton`
- [ ] Outcomes follow the surface rule above — banner if the screen stays,
      SnackBar if it pops, and never a SnackBar inside a live region
- [ ] A banner is retired when its failure stops applying (edit, mode switch)
- [ ] Arriving outcome banners are left to reveal themselves; `reveal: false`
      only for a persistent one
- [ ] Status uses `BgeStatusColors` **with its icon**
- [ ] Checked at 320dp and 200% text scale
- [ ] Checked in dark, light, and high contrast
- [ ] Strings are ARB-backed with an `@key` description
- [ ] `melos run test` and `melos run test:goldens` pass
