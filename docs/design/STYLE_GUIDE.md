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

Chips are `secondary` unless they show the active state, which is `primary`'s:
the game detail page's ownership chips are filled in `primary` where the user
owns the game, and outlined in it where they don't (#708).

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
  but it is still capped, because nothing stretches to the monitor. A surface
  that mixes rows *with* prose keeps 480: the prose decides, which is why
  `FeedbackReviewScreen` takes the reading measure and `SettingsScreen` does
  not.
- Dialogs take `contentMaxWidth` too, from the theme. `BgeTheme` caps every
  dialog at the reading measure, so a `showDialog` call site sets no width of
  its own. A dialog is a title, a sentence or two and its buttons: prose, so the
  prose decides. Left to Flutter, a dialog may grow to the window minus 40dp
  insets, up to 2480 on a 2560 monitor. Bottom sheets keep Flutter's own 640
  cap. The cap reaches Flutter's pickers too. The date and time pickers
  narrow and stay dialogs: in a landscape window the date picker goes from 496
  to 480 and the time picker from 572, and neither overflows. The calendar form
  of `showDateRangePicker` is the exception. Flutter builds it as a plain
  `Dialog` sized to the whole window with no insets, so wherever the window is
  wider than 480, a phone held landscape included, the cap turns a full-screen
  picker into a full-height 480 strip. A range picker lifts the cap in its
  `builder`, by wrapping the child in a `DialogTheme` whose constraints are
  `const BoxConstraints()`. The app has no picker yet, so check the first one
  against this.
- `breakpointMedium` (600) / `breakpointExpanded` (840).

**Measures are caps; breakpoints are thresholds.** A cap is already adaptive —
below it the content simply fills the window, so the same widget fits a phone
and stops short on a monitor with no window-class check. Reach for a breakpoint
only when a layout should *change form* (rail vs. bottom bar, one pane vs.
two), never to pick a width. `paneMaxWidth` and `breakpointExpanded` share a
value today and are still separate tokens: retuning one must not silently move
the other. Two things read them so far: `showBgePopup` (a sheet below
`breakpointMedium`, a dialog from there up) and `bgeGridColumns` (the column
count of a cover grid) (#707, #710). The home page stopped setting its events
and stats sections side by side (#669); the next readers are expected to be
the navigation shell (#414), once a section of equal standing with home
exists, and the first two-pane layout (#46). A layout that reads one
reads it against the window, not a `LayoutBuilder`: under the page's padding a
`LayoutBuilder` reaches 840 only at a window of 888.

---

## 4. Widgets

Use these. They exist because the hand-rolled versions drifted.

| Widget | Replaces | The thing it guarantees |
| --- | --- | --- |
| `BgePage` | the hand-rolled Scaffold→SafeArea→Center→Scroll→ConstrainedBox block in all 12 page screens | Always scrollable (content that fits at 1.0 does not at 200% text scale), always width-constrained; `footer:` pins an action below the scroll at the same measure; with a `floatingActionButton`, the content ends with room for it, so the last row scrolls clear of the button (#467); `BgePage.slivers` gives a list surface one real viewport, so it keeps both its collection semantics and its laziness; its `header:` sits above the slivers, scrolls with them and stays in the semantics tree however far the page is scrolled, where a sliver among the content leaves the tree past the cache extent; a banner in the header is heard as it arrives on iOS at any depth, and on Android when the header is on screen or more than a cache extent (250dp, a viewport with a footer) above the view; in between, Android stays silent and the banner's reveal puts it on screen (#516) |
| `BgeKeyedSliverList` | a `SliverList.builder` whose rows carried their key one level in, or keyed the child with no lookup (#549) | Each row is keyed and the sliver finds it by that key, so a row keeps its state — focus included — when rows above it leave or arrive |
| `BgeKeyedSliverGrid` (with `bgeGridColumns` and `bgeCoverGridDelegate`) | a `SliverGrid.builder` for a grid whose tiles can leave or move, which would lose a tile's focus with its position | The grid sibling of `BgeKeyedSliverList`: each tile is keyed by its id; the columns come from the window width, not the grid's own, so a cover grid reads the same breakpoints as everything else (#710) |
| `BgeUnfoldingCoverGrid` | nothing: a strip under a grid row had no slot, as each screen drew its covers as one `SliverGrid` (#711) | A `BgeKeyedSliverGrid` of covers that opens a full-width strip under one item's row, padded `spaceSm` above and below as the rows are spaced; the rows up to the strip stay the first sliver, so the item whose strip it is keeps its element and its focus as the strip opens and closes; the covers after it count on from the ones before it, and the strip takes no index; another item's strip is a new one. A tile after the strip is built again as the strip comes and goes, so its focus goes through a `BgeFocusHandoff`. `BgeUnfoldingCovers` holds which item is open, for tiles that open their own: one at a time, folded once the item goes or has no strip, and kept by the item's id while its tile changes form |
| `BgeCoverTile` | a cover wrapped in a hand-built tap target and a title below it | Cover only: the title is the accessible name, not drawn text; a fixed 120dp on a shelf, and `extent: null` fills a grid cell (#707, #710); `stackCount` marks the picture alone with a `BgeStackMarker`, so the tile stays one target of the same size and its label speaks the count (#709); `expansions` (`BgeCoverExpansions`) adds a badge at the picture's bottom end, in the tertiary container colours with a puzzle piece and the count, a button of its own after the cover with an expanded state, at least 48dp square, inside the cover and drawn as big as it takes presses, with the same toggle on the cover as a custom action; `marked` outlines the picture in tertiary with a broken link at its top start, drawn only, for the label to say (#711) |
| `BgeStackMarker` | a cover or row per entry for a game owned more than once (#709) | Two cards offset behind the child toward the top and the end, on the left in a right-to-left language, and a count badge in the secondary colours, never the error ones; nothing reaches outside the child plus `reachOf` each way, the badge scaling down at large text instead; it adds nothing to the semantics tree, so the host's label carries the count |
| `BgePointerFocus` | the `:focus-visible` handling copied into each control that takes focus from a tap, the cover tile's and the collection list's stack rows (#707, #709) | A mouse's or a trackpad's press hides the control's ring (`BgeFocusRing.suppressed`) and its ink's focus tint (`pointerFocusColor`) until the next key press, so the focus a pop-up or a page it opened hands back isn't drawn for a user who never touched the keyboard; a touch or a stylus sets nothing, as the highlight mode hides feedback already. One known limit: an ink highlight keeps the alpha it was first drawn with, so the tint stays hidden until the control's next focus while the ring comes back at once — the ring is the reliable cue |
| `BgeFocusHandoffScope` (with a `BgeFocusHandoff` around each item) | nothing: when a game's item changed form — one entry to a stack, top level to under its base game — its focus went with the old widget, and a pop's restore had nowhere to land (#769, #711) | For a keyed list or grid whose items change form, or show one thing in more than one place: one scope around the item slivers, and each item names what it shows. Focus on an item that leaves goes to its replacement at the end of the frame that replaced it, a frame later for focus a click gave (below), and a pop's restore goes there too once the route above has gone, a page or a pop-up, unless the user has moved focus since; the replacement in the same place wins, else the one built first; within it, the control in the place of the one that had focus, in widget order, such as a cover's expansions badge, else its first; focus a click gave stays undrawn in the new form, ring and tint (`BgePointerFocus`), with focus waiting a frame on the page while a replacement built for the other kind of focus rebuilds, and going on to the newest replacement if the game changes form again meanwhile. No semantics node, no Tab stop, no render object of its own. One known limit: a focused item scrolled out of a lazy list's cache counts as leaving, so focus goes to a copy of the same game that is still built, if there is one |
| `BgeLayoutToggle` (with `BgeRememberedLayout`) | a per-screen list/thumbnail switch and the preference behind it | One control for the choice, with its selected state announced; the choice is remembered per user, and the builder gets `null` until it has been read, so a screen holds its rows back until then rather than flash the other layout (#710) |
| `showBgePopup` | `showModalBottomSheet` at every width, a wide strip along the bottom edge from 840dp up | A bottom sheet below `breakpointMedium`, a dialog from there up, on the root navigator; a page pushed over it removes it once the page has arrived, so back lands where the pop-up was opened from (#707) |
| `BgeSubmitButton` | all 6 hand-rolled in-flight buttons | Cannot overflow (#163); disabled-not-hidden; keeps its accessible name; announces via live region |
| `BgeInlineBanner` | 3 divergent error banners | Tone → color *and* icon; announces on appearance **and scrolls itself into view**; one semantics node |
| `BgeTextField` | 3 divergent field implementations | Visible label; live-region error announcement; 48dp password toggle; theme border |
| `BgeSearchField` | nothing: a list narrowed as the user types had no shared field to do it with. The game search keeps its own field, because it submits a query rather than narrowing a list | A visible label, never a hint; a clear button shown only while there is text, which keeps focus on the field when pressed, with its name as tooltip and accessible name, and a 48dp target; `onChanged` on every edit and `''` on clear, not debounced; it owns its text, so `initial` seeds once (#715, #516) |
| `BgeDropdownField` | reactive_forms' `ReactiveDropdownField` in 4 form menus, whose menu covered the field (#649, #648) | Visible label; the menu opens under the field, as wide as it, and above it near the bottom of the screen; a long choice wraps, closed and open; a button with an expanded state that Enter or Space opens, the arrows move through and Escape closes, with focus back on the field after; read-only stays focusable; live-region error announcement |
| `BgeFormActions` | a submit's failure placed by hand: above the button on server-add, at the top of the page on auth and create-household (#227) | The failure sits directly above the action it answers, one step away and exactly as wide; its title is a decision each call site writes down |
| `rejectSubmit()` on a `FormGroup` | `markAllAsTouched()` alone, which renders every error and leaves the first one wherever it is (#230) | Every error shown; focus on the first invalid control, and the whole field on screen, label and error included — which focus alone does not do |
| `BgeErrorState` | the bootstrap failure screen and the session-unreachable view, which had drifted apart | Title and body announced as one live region; retry autofocused; the icon says nothing; content, not a page — the caller supplies the `BgePage` |
| `BgeInertButton` | a busy control's own semantics node, focus node and press guard, copied per control with the copies drifting (#607) | Enabled while inert, so it keeps focus; a press does nothing; one semantics node, the same inert or not, that reads as not enabled and offers no tap while inert; a held Enter or Space presses once; a null `onPressed` disables it in place, taking no focus, so a control that is inert after its own press and disabled after another's keeps one node; `selected` keeps a choice's selected state through all three (#508) |
| `BgeFabLabel` | a `FloatingActionButton.extended`'s plain `Text` label, which at 200% text on a narrow window made the button wider than the window and pushed its start edge off screen (#50) | Held to what the window leaves it after the button's margins, padding and icon, and scaled down to fit on one line, never cut; a label with room keeps its size |
| `BgeRefreshBanner` | the stale-data banner and its retry, hand-built per cached list and detail screen, and the catalog's from-cache banner, with copies that had drifted (#269, #300) | Warning tone at rest, info while refreshing; the failed copy names no cause; the retry stays enabled and focused while busy — a press does nothing, the label swaps to the in-progress string, and a held Enter or Space starts one pass (#573, #607); one semantics node, the same at rest and busy |
| `BgeLoadingState` | a bare `CircularProgressIndicator` on each screen that waited | A spinner with no skeleton; its label is one live region read once on appearance; the spinner itself says nothing; content, not a page (#49) |
| `BgeEmptyState` | ad hoc "nothing here" text, which drew and announced differently per screen | An optional icon, a title, an optional body and an optional action; title and body are one live region; the icon says nothing; the action is not autofocused, because an empty list is an answer, not a failure (#49) |
| `BgeStateSliver` | a hand-wrapped `SliverFillRemaining` around a state on a sliver page | Fills the rest of the page and centres the state; `hasScrollBody: false`, so a state taller than the room, at 200% text, scrolls with the page instead of overflowing it (#49) |
| `BgeOfflineStrip` | nothing: the app showed no sign that it was offline, and an offline banner per page would have scrolled away and been rebuilt on every route | One strip at the top of the window, hosted by the shell, so it reaches every route; it takes the status-bar inset while it shows and no height while hidden; one merged live region whose label change announces; not focusable; motion through `BgeMotion.durationOf` (#49) |
| `BgeOnlineOnly` (with `BgeOnlineOnlyLabel`, `BgeOnlineOnlyNote`, `BgeOnlineOnlyMenu`, `BgeOnlineOnlyPopupMenuItem`, and the `BgeConnectivityScope` they read) | a direct-write control that was live offline and failed on press, with only the failure banner to say why | Offline, the control is disabled and says why: the reason is its accessible hint, once, and drawn once per row or group; the same tree online and offline, so the control keeps its state; with no scope everything reads as online (#49) |

### Empty and loading states

Each of the three things a surface can say instead of its content has one widget:

| The surface is | Use |
| --- | --- |
| Waiting, with nothing to show yet | `BgeLoadingState` |
| Answered, and there is nothing to show | `BgeEmptyState` |
| Failed, and there is nothing else to show | `BgeErrorState` |

All three are content, not pages: the caller supplies the `BgePage`. A whole-surface
wait is a `BgeLoadingState`; a paged list's loading tail is not one, and keeps
its own row. On a sliver page, wrap the state in `BgeStateSliver`, which fills
the rest of the page and centres it.

A state inside a *section* of a page is the exception: the DataGateway language
worklist, and the search's no-results line under its count. There the state
sits in a `SliverToBoxAdapter`, because `BgeStateSliver` fills the rest of the
viewport and would take the room of everything after the section.

### List surfaces

A screen whose content is a list is built on **`BgePage.slivers`**, not a
`ListView` in `child:`. The box constructor already supplies a scroll view, so a
nested list has to be shrink-wrapped and made non-scrollable — and that splits
the collection semantics (the scrollable node loses its `scrollChildCount` while
the node that still carries it cannot scroll, so a screen reader stops saying
"item 3 of 9") as well as forfeiting per-viewport realization. `.slivers` gives
the page one real viewport, so a `SliverList` keeps both.

**`slivers:` takes any sliver.** It is a `List<Widget>` and a sliver is a
widget, so a paginated list goes straight through — including the shape a
search screen actually has, with a query field above the results.

**A list whose rows can leave or move while the user is on it** — rows from a
cache, a purge, a discard — uses **`BgeKeyedSliverList`**, with the row's id as
its key. A bare `SliverList.builder` matches rows by position, so a keyboard
user on a row loses their place when a row above it leaves (#549). The key goes
on a wrapper the list puts around each row, so the row does not carry it too:

```dart
BgePage.slivers(
  title: Text(l10n.searchTitle),
  width: BgePageWidth.pane,
  semanticChildCount: results.length,
  slivers: [
    const SliverToBoxAdapter(child: SearchField()),
    BgeKeyedSliverList<Result>(
      items: results,
      keyOf: (result) => ValueKey(result.id),
      itemBuilder: (context, result) => ResultRow(result),
    ),
  ],
)
```

**`semanticChildCount` is required, and it is what the list holds right now.**
`ListView(children:)` infers the count; a `CustomScrollView` cannot, so the
caller has to say. A paginated caller passes the loaded count and lets it grow
as pages arrive — **not** null-until-the-last-page, which announces nothing at
all. This is what `ListView.builder` already does (`semanticChildCount ??
itemCount`): the number describes the children the viewport holds, not a total
sitting on the server.

Nothing verifies it for you. `ListView.builder` asserts the count against its
`itemCount`; `CustomScrollView` asserts only `>= 0`, and `BgePage` cannot see
inside the slivers it is handed. A count that disagrees with the list is silent,
so it belongs in the screen's test.

### Tabs

A screen takes tabs when it holds **two or more views of one thing that are
each a destination in their own right**: an event's details and its games pool
(#516). Not to hide sections of a short page, which scrolls instead, and not to
switch a mode: a `SegmentedButton` is for that, such as a layout or a filter.

- **Tabs are Material's `TabBar`**, not scrollable, with a `Tab` each. It gives
  every tab the tab role, its selected state and its place, "tab 1 of 2", so
  a screen builds none of them itself.
- **A tab's label scales down, never clips.** A tab is one line tall and can't
  wrap, so the label's `Text` goes in a `FittedBox(fit: BoxFit.scaleDown)`, as
  a chip's does. Check a tab bar of two tabs in a 320dp window at 200% text.
- **What answers the whole screen stays above the bar**, on every tab: the
  refresh banner and the outcome banners. On a sliver page they go in
  `BgePage.slivers`' `header:`, which keeps them in the semantics tree
  however far the page is scrolled. When a banner there is heard, on iOS
  and on Android, and where its reveal stands in, is in the `BgePage` row
  of the table above. That reveal scrolls an outcome banner into view as it
  arrives, which takes the page from wherever the reader was; it is
  accepted here because these banners answer the whole screen. This is the
  exception to "an outcome on a long list sits in the
  footer" (Error and outcome surfaces): it answers the screen, not a row of
  one tab's list. Pass the header on every build, empty when there is nothing
  to say, so the call site keeps one shape; an empty header adds no node and
  no height.
- **One scroll view, not a `TabBarView`.** A tab that holds a list makes the
  page `BgePage.slivers`, and the bar sits in it as a sliver above the
  selected tab's slivers, which the bar swaps. `semanticChildCount` follows
  the selected tab: what its list holds, and null on a tab with no list. The
  bar keeps its place as the tabs swap, so focus stays on the tab chosen.
- **The selected tab outlives the screen's own rebuilds.** Hold the
  `TabController` above the screen's bloc builders, so no read, write or clock
  tick sets it back. A `DefaultTabController` does that, and its
  `animationDuration` goes through `BgeMotion.durationOf`, so under reduced
  motion the indicator moves at once; it keeps the tab when that setting
  changes. The tab isn't in the route: a screen opens on its first.
- **A screen that can't show a tab shows none.** Where one tab would have
  nothing to hold, the page is the other alone, with no bar, rather than a
  bar with one tab or a dead one.

### In-flight forms

One rule, app-wide: while a submission is in flight, fields go **`readOnly`,
never `enabled: false`**. A disabled field leaves the focus order, so a
keyboard or screen-reader user mid-form has the control vanish underneath them
for the duration of a network call. Read-only keeps it present and readable and
still closes the keyboard submit path. `BgeTextField` and `BgeDropdownField`
deliberately expose no `enabled` so two screens cannot make opposite choices
about the same moment.

The in-flight signal is carried by `BgeSubmitButton` — label swap plus spinner,
in a live region — not by greying the form out.

### Rejected submits

A submit the form refuses calls **`form.rejectSubmit()`**, never
`markAllAsTouched()` on its own. Marking touched renders the errors wherever the
fields are, and a user who scrolled down to reach the button is no longer
looking at them: measured at 320×480 and 200% text, a rejected register left
its first error 145dp above the viewport. `rejectSubmit` also moves focus to the
first invalid control, which puts a keyboard or screen-reader user on it, and
brings the whole field on screen, label and error included. Focus alone does
not: a dropdown is not scrolled to at all, and a text field scrolls only as far
as its caret, which at 200% text left its label clipped above the viewport.

"First" is reading order, the order Tab moves through, taken from where the
fields are laid out. The order the controls are declared in the `FormGroup`
does not matter, and an invalid control with no field built for it is passed
over.

### Where the primary action goes

Inline, at the end of the form, unless the page is a **flow step**, a **long
review surface** or a **long picker**. Those pin it with `BgePage.footer`, and
so does the outcome of an action on a **long list** or a long page, which has
no form to sit on. A long picker pins because its action counts the picks
across a list of any length: at the list's end it would be out of reach for
as long as the user is choosing.

The pages that pin, and this list is where a new one is added:

- feedback compose and review;
- the Offer games page, a picker of the viewer's whole collection, whose
  Offer button counts the picks (#516);
- the banners that answer actions on a DataGateway's page: on the DataGateway
  itself, and on its language worklist (#457);
- an event's screen, whose footer holds the line saying how many games a run
  of offers is offering and how the Games tab's last writes went, to the
  pool and to the nominations, on either tab, and the Games tab's stale-data
  banners for the pool and the nominations (#516, #517, #851).

The reasoning, and the measurements behind it, are on `BgePage.footer`:

- a flow step pins because the step it hands over to does, and an action that
  scrolls on one step and is pinned on the next moves at the handoff;
- a centred first-run page does not, because a pinned action renders below
  whatever the column continues with (auth's sign-in alternatives), and at 320dp
  and 200% text the pinned band eats a quarter of the body;
- a short form does not, because its button already scrolls into reach;
- an outcome on a long list does, because the list moves on: inside it a banner
  is built only near the view, so one that lands after the user has scrolled
  away is neither seen nor announced (see Error and outcome surfaces).

Two steps that hand over to each other also build their insets the same way:
from the page's `padding`, not from insets inside each row. Review once put its
16dp inside the column, which lined up with compose on a phone and was 16dp
narrower a side on a desktop window — no padding compose could pass would have
closed that.

### Online-only controls

A **direct write** is a request that goes to the server and does nothing
without it. While the app is offline its control is disabled, through the
`BgeOnlineOnly` family, and says why. A **queued write** is stored on the device
and sent when the connection returns, so its control stays enabled. Offline
is the state the app is built to work in, and a queued write is the work.

Five operations are queued today (`SyncOperation`): add, update and remove a
collection entry; create a household; create an event. Every other write is
direct. A new direct-write control takes the gate; a new queued operation
leaves its control alone.

The failure banner stays as the fallback. The gate follows a debounced flag
(the strip's 2 s wait), so a write can still start in the moments before the
flag turns, or fail for a server that is down while the device is online, and
the screen's outcome banner answers it as before. A confirm dialog that is
already open when the connection drops is not gated either; the banner covers
it.

The pieces, and the rules the build proved:

- **The shell publishes the state.** `OfflineStripHost` draws the
  `BgeOfflineStrip` and puts a `BgeConnectivityScope` over the app. A control
  reads `BgeConnectivityScope.offlineOf(context)` for `onPressed: null`; the
  widgets below explain. The caller still disables the control; the wrapper
  does not.
- **The strip waits 2 s, then holds "Back online" for 2 s.** A connection that
  drops and returns inside the wait changes nothing on screen. Controls come
  back the moment the connection does, while the strip is still saying it. The
  host removes the top inset from the content below for as long as the strip
  shows, so no app bar insets the status bar twice. The content sits in a
  semantics container of its own, because every route's modal barrier drops the
  semantics painted before it, and the strip would otherwise never reach a
  screen reader.
- **The reason shows once per row or group, and each control still carries it
  as its hint.** Wrap each control in `BgeOnlineOnly(showNote: false)` and put one
  `BgeOnlineOnlyNote` under the group. Never wrap a group in one `BgeOnlineOnly`:
  its `MergeSemantics` folds a row of chips into a single node.
- **Add the note only while offline.** A zero-size child still takes a
  `Column`'s `spacing`, so a note that is always in the tree leaves a gap
  online. Build it under `if (offline)`.
- **A tile carries the reason in its own merged label.** Use
  `BgeOnlineOnlyLabel` as the tile's title or a menu item's label: it adds the
  reason as a second line while offline, and the item merges both lines, so the
  reason is read once, with the item.
- **A menu that is open when the connection drops closes.** With every item
  disabled, Tab cannot leave the menu's panel (Escape can; measured). Own the
  menu's controller with `BgeOnlineOnlyMenu`, which closes it on the drop. One
  opened while already offline stays open, so its items can be read.
- **Popup menu items follow the scope while open.** A `PopupMenuItem` fixes
  `enabled` when the menu opens, so use `BgeOnlineOnlyPopupMenuItem`, which
  builds from the live scope. `onSelected` still guards a press that lands as
  the connection drops.
- **One tree shape, online and offline.** `BgeOnlineOnly` builds the same
  widgets either way, so the control under it keeps its element, its state and
  its semantics node when the connection flips; online its hint is empty and it
  draws nothing more. Keep the call site to one shape too: add a note with `if`
  after the content it follows, never by moving that content between parents,
  or a live region in it is announced again on every flip.

### Error and outcome surfaces

Three screens once answered this three different ways, on contradictory
assumptions about what a SnackBar announces (#191). One rule now, and the
question it turns on is **does the screen survive the outcome?**

| Situation | Surface |
| --- | --- |
| Outcome on a screen that stays | `BgeInlineBanner` (`announce: true`) — through `BgeFormActions` when it answers a form's submit, in `BgePage.footer` when it answers an action on a long list |
| Outcome whose screen pops, or a notice belonging to no screen | bare `SnackBar` |

A failure that leaves the screen nothing else to show — the app could not
start, the session could not be checked — is not an outcome either. It *is* the
screen: `BgeErrorState` inside the page's `BgePage`, with a retry.

A state change with no outcome copy — a mode switch, a filter applied — is not
on this table. It takes a **live region on the text that changed**, per the
accessibility rules below; it does not take a `SemanticsService` announcement.

**A form's failure sits on the submit it answers.** `BgeFormActions` puts the
banner directly above the button, so a user who scrolled down to reach it reads
the answer where they pressed. At the top of the page, as auth and
create-household once had it, reading it meant being scrolled away from the
button — and on create-household, with the real theme, that long scroll was the
one a tap cuts short, leaving the banner off screen (#233).

**An outcome on a long list sits in the footer.** A form's banner sits on its
button, where the user pressed. A long list has no such place, because the
list moves on. Inside it a banner is built only near the view, so one that
lands after the user has scrolled away is neither seen nor announced; above
it, a banner takes the page from wherever they were working, and taking it
away moves every control below it up under the pointer. In `BgePage.footer`
it is always built and on screen, so its live region always fires and it
moves no row. The DataGateway page is the case (#457): what an action on the
DataGateway answered, then what an action on its language worklist answered,
stacked in the one footer, each with its own Dismiss. It is the one exception
to a banner living inside the page's scroll view, and so to having no height
cap (#228): the footer holds at most half the body and scrolls, so even a tall
banner there stays reachable. A banner there reveals itself within the
footer's own scroll view, so the page doesn't move.

On a screen with tabs, a banner that answers the whole screen rather than a
list is not this footer's: it stays above the tab bar, in the page's
`header:` (Tabs, above).

Such a footer is passed on every build, and renders nothing while there is
nothing to report. `BgePage` builds a different tree with a footer than
without one, so a footer that came and went would lose the scroll position and
the focus.

**A sliver page with a footer keeps one viewport of content built past its
edge (#457).** A footer that arrives takes room from the end of the view, so
the rows there leave it, and on a lazy list a row that far out of view is no
longer built — which loses keyboard focus on it, or on its way back to it. The
page keeps one viewport built past each edge of the view, where the default is
250dp. One is enough because a footer takes at most half the body. A page
without a footer keeps the default.

**Title a failure when some of its operation's messages state only a cause.**
"Could not reach the server. Check your connection." never says that *signing
in* failed, so sign-in and register are titled; create-household's one message
names the operation, so it is not. The rule is per operation, and
`BgeFormFailure.title` is required so that every call site writes its answer
down — `null` included.

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
  wrapped sentence. (It may be that tall on purpose: it sits inside the
  page's scroll view, which scrolls past a tall banner like any other
  content, so #228 decided against a height cap.)
- **Pass `reveal: false` for a *persistent* banner** — one that stays on a
  screen as furniture, not news. It scrolls itself into view on every mount,
  which fights a restored scroll position. The offline indicator is not one:
  it is `BgeOfflineStrip`, hosted by the shell at the top of the window, outside
  any page's scroll view. A banner built **lazily inside a list**
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
into all three app binaries. An exception is a decision, recorded with its
reason in `ui.dart`'s library doc.

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
- **Visible focus** — `focusOutlineWidth`, never removed. Text fields get a
  border that wide. Filled, tonal, icon, text, outlined and elevated buttons
  get a `primary` ring on keyboard focus only (#644): `focusRingGap` outside
  the shape on filled, tonal and icon buttons, and inside the edge on text,
  outlined and elevated buttons, which Flutter clips to their shape. A mouse
  or trackpad press anywhere hides every ring until the next key press. An
  outside ring reaches 4dp past the shape. A scroll view's edge is handled:
  once keyboard focus has brought the button into view, the ring scrolls
  the rest of itself in. Keep
  any other clipping edge, such as a clipping card's, at least that far from
  such a button. A button
  that sets its own shape passes it to `BgeButtonFocusRing.builder` in its
  style, or the ring keeps the theme's. On a toned container, as in a banner,
  the ring takes the container's
  foreground, since `primary` was never solved against it.
- **The release-time audit script** is
  [`ACCESSIBILITY_AUDIT.md`](ACCESSIBILITY_AUDIT.md): what the automated checks
  cover, and the manual screen-reader walk for each platform.
- **No meaning by color alone.**
- **Live regions, not `SemanticsService.announce`** — announcement events are
  deprecated on Android because they force TalkBack to clear its speech queue.
- **Disable, don't hide**, in-flight controls, and keep their accessible name. A
  control that vanishes mid-interaction moves focus and loses the user's place.
  One that must keep focus through its own action — the refresh banner's retry,
  the household member menu, the poll's retry — stays enabled and ignores
  presses instead, because a disabled Material button cannot hold focus (#607).
  A button builds that from `BgeInertButton`. Those named are examples of the
  rule, not a complete list: the data gateway detail's interview button and
  capability switches (#457, #660), and the auth screen's provider buttons
  while a sign-in is open (#583), stay enabled and inert the same way. A
  control with no focus to keep is disabled as before.

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

- [ ] Built on `BgePage` — `BgePage.slivers` for a list surface, the box
      constructor otherwise
- [ ] The primary action is inline at the end of the form, unless the page is
      a flow step, a long review surface or a long picker, which pin it with
      `footer:`, as does an outcome on a long list; a page that pins is
      listed in "Where the primary action goes"
- [ ] Measure: `width: BgePageWidth.pane` for rows that are a label plus a
      trailing control; the default 480 for prose, and for a surface mixing
      prose with rows
- [ ] Dialogs set no width: the theme caps them at the reading measure. A
      calendar range picker is the exception, and lifts the cap
- [ ] A breakpoint changes a layout's form, never its width
- [ ] A list surface passes `semanticChildCount` — the count it currently
      holds, grown as pages arrive, never left null on a known list
- [ ] A list whose rows can leave or move is a `BgeKeyedSliverList`, keyed by
      the row's id; the row itself does not carry the key (#549). A grid whose
      tiles can leave or move is a `BgeKeyedSliverGrid`
- [ ] Tabs only for views that are each a destination: Material's `TabBar`,
      labels that scale down, banners above the bar in the page's `header:`,
      and a selected tab held above the screen's rebuilds (Tabs, above)
- [ ] Loading, empty and failure states use the shared widgets
      (`BgeLoadingState`, `BgeEmptyState`, `BgeErrorState`), in a
      `BgeStateSliver` on a sliver page
- [ ] Direct-write controls are gated offline through `BgeOnlineOnly`; queued
      writes are not
- [ ] A drag-interactive surface (a scroller the mouse can drag, a reorderable
      list, a slider, a swipe to dismiss) wraps itself in
      `SelectionContainer.disabled`, and is checked with a mouse on a desktop
      platform (#338)
- [ ] Spacing from `BgeGap` / `BgeTokens`; no literals
- [ ] Colors from `Theme.of(context).colorScheme`; no `Colors.*`
- [ ] Type from `Theme.of(context).textTheme`
- [ ] Forms use `BgeTextField`, `BgeDropdownField` + `BgeSubmitButton`
- [ ] A submit that can fail on a screen that stays is wrapped in
      `BgeFormActions`, with its `title` decided by the rule above
- [ ] A rejected submit calls `rejectSubmit()`
- [ ] Outcomes follow the surface rule above — banner if the screen stays,
      SnackBar if it pops, and never a SnackBar inside a live region
- [ ] A banner is retired when its failure stops applying (edit, mode switch)
- [ ] Arriving outcome banners are left to reveal themselves; `reveal: false`
      only for a persistent one
- [ ] Status uses `BgeStatusColors` **with its icon**
- [ ] Checked at 320dp and 200% text scale
- [ ] Checked in dark, light, and high contrast
- [ ] A test file in the screen's package has a `group('accessibility audit')`
      naming the screen (`melos run check:a11y-audit`)
- [ ] Strings are ARB-backed with an `@key` description
- [ ] `melos run test` and `melos run test:goldens` pass
