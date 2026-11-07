# Board Games Empire — Accessibility Audit

The release-time script for accessibility. Companion to
[`STYLE_GUIDE.md`](STYLE_GUIDE.md) §5, which says what each screen must do;
this document says how to check that it still does, and what no automated
check can see. Written for #50, which built the automated half. The walk on
devices belongs to #70.

---

## 1. When to run it

- **Each release.** Run the automated checks (§2), then the manual script
  (§4) on every platform being released.
- **Before closing an accessibility issue.** Re-run the checks the issue's
  fix touches, and the part of §4 that covers the symptom.

The automated checks run in CI on every change. Run them locally with:

```sh
melos run check:a11y-audit --no-select   # every screen has an audit group
melos run test --no-select               # the audits, flows and token tests
```

---

## 2. What the automated checks cover

### The screen audit

`auditScreen`, in
`packages/testing/support/lib/src/widgets/accessibility_audit.dart`, runs
Flutter's accessibility guidelines on a screen in one state:

- `androidTapTargetGuideline` (48dp)
- `labeledTapTargetGuideline` (every tap target has a name)
- `textContrastGuideline` (4.5:1 for body text), run with the Ahem test font.
  The probe that chose this form is under "This run's results".
- `iOSTapTargetGuideline` is left out: its 44pt bar is under the 48dp one.

Each call checks the state at **320dp × 2.0** and **390dp × 1.0**, in **light
and dark**. The helper applies each cell's text scale itself, and fails a cell
whose screen didn't draw at that scale and in that theme, as when a harness
sets its own (#767). High contrast stays with the token tests. A test calls it
for every state its screen has (ready, empty, failure, loading and the rest),
in a `group('accessibility audit')`. Loading states pass `settle: false`. A long
state is audited a second time, either scrolled to its end or as a whole page
in a tall view.

Home's sections (upcoming events, the stats card, and the "Recently added" and
"Something to play" rows) are composed in `BgeApp`, outside any screen, so
`HomeScreen`'s own audit hosts placeholders in their place. Each section is
audited in its own package instead, in every state it draws, beside its tests
under `test/home/` in events, collection and catalog.

### The coverage check

`tool/check_a11y_audit.dart` (`melos run check:a11y-audit`, also in CI's
`test-files` job) fails when a `*_screen.dart` under a package's `lib/` has no
test in the same package holding both `group('accessibility audit'` and the
screen's class name. A new screen fails it until someone writes the group.
It prints the exempt screens on every run. The match is a text match, so it
catches the screen nobody thought of, not a group that audits nothing. The
reviewer checks that.

### Keyboard flow tests

`tabOrder`, `expectTraversable` and `expectFocusReturnsAfterDialog`, in
`packages/testing/support/lib/src/widgets/keyboard_traversal.dart`, check
that the Tab order, read as each stop's accessible name, matches a reviewed
list in reading order; that Shift+Tab walks it in reverse; that no stop comes
round twice before focus wraps, so nothing traps it; that focus wraps within
the step limit; and that focus goes back to the opener when a dialog or route
closes. A stop with no name is listed as `<unnamed>`, so a reviewed list shows
it, but the helpers don't fail on it by themselves. The flows:

- Server add, sign-in, and home → create household:
  `packages/app_shell/test/widgets/bge_app_keyboard_flow_test.dart`. The home
  leg walks the signed-in home, the open drawer and the create-household form,
  and checks that Escape closes the drawer with focus back on its menu button.
- Create event: the `keyboard` group of
  `packages/features/events/test/widgets/create_event_screen_test.dart`
- Game search: the `keyboard` group of
  `packages/features/catalog/test/widgets/game_search_screen_test.dart`

### Token contrast tests

`packages/ui/tokens/test/accessibility/` and its neighbours check AA contrast
(7:1 in high contrast) on every authored colour pair and on body text against
every surface role, the selection colour, the offline strip, the type scale
at 200% and reduced motion.

### The button focus ring (#644)

`packages/ui/tokens/test/accessibility/bge_button_focus_ring_test.dart` and
`packages/ui/tokens/test/goldens/bge_button_focus_ring_golden_test.dart` pin
the ring: outside the shape with a gap on filled, tonal and icon buttons,
inside the edge on text, outlined and elevated buttons, and in the banner's
foreground on toned banners. A mouse or trackpad press anywhere hides every
ring until the next key press without Control, Alt or Meta, as a browser's
`:focus-visible` does. So focus that lands on a button after a click stays
unringed: handed back as a dialog closes, or taken by a button that
autofocuses. The same file holds the skipped checks for the controls the ring
doesn't reach yet (see §5).

---

## 3. What they don't cover

Know these limits before trusting a green run.

- **Derived Material roles.** Contrast is guaranteed for authored pairs.
  A role Material derives from them carries no guarantee, so a screen using
  one needs a look.
- **Real screen readers.** Every semantics check reads Flutter's semantics
  tree. Nothing says how TalkBack, VoiceOver or a browser reader speaks it.
- **Web keyboard behaviour (#661).** The VM's default shortcuts differ from
  the web's (arrows are scroll intents on web), so a keyboard test passing on
  the VM says little about a browser.
- **Anything needing a device:** gestures, haptics, platform focus
  hand-offs, text-scale settings, the system's own colour modes.
- **Text the guideline can't see.** `textContrastGuideline` measures only a
  semantics node whose label equals the text of one on-screen `Text`. Merged
  titles and bodies, field labels and hints, subtitled rows and drawer labels
  go unmeasured.
- **Disabled controls.** A disabled control's dimmed label fails the
  contrast guideline, but WCAG 1.4.3 exempts inactive controls, so a state
  with one passes `textContrast: false` and says why in a comment. The same
  controls pass in the state where they are enabled.
- **Clipped controls.** The tap-target guideline measures a control clipped
  by the viewport at its clipped size, so a scroll that leaves a field half
  under the top edge fails it, though nothing a user meets is wrong. Such a
  state is audited as a whole page in a tall view instead, as above.
- **Dialogs** opened from a screen are mostly not audited.
- **The offline notice** the shell draws isn't in the screen audits.
- **The drawer entries** read "Tab n of m" (#763).
- **Wrapped button labels at 200%.** The ring's builder makes Flutter clip
  `TextButton()`, `OutlinedButton()` and `ElevatedButton()` to their shape, so
  a label that wraps to two lines loses a few glyph pixels at the curved ends
  (#764).
- **Shift+Tab round a long lazy list.** Back at the top of a lazily built
  list, its last children are no longer built, so Shift+Tab from the first
  control wraps to the last one still built rather than the list's end
  (#765).
- **Focus ring after mouse use.** A mouse press anywhere hides every ring
  until the next key press. The tests drive it with Flutter's own pointer
  and key events. On web with semantics on, a click can reach a button as a
  semantics tap rather than a pointer press, which the flag doesn't see, so
  the device walk should check the ring after mouse use there.
- **Nine screens are exempt** while other units rewrite them (see the
  coverage table below).

---

## 4. The manual script

Run it on a real device or browser. Use a build that reaches every screen
below: a signed-in account with a household, an event, and a server with
games.

### Three checks on every screen

On each screen of each flow:

1. **Every control has a name.** Move through the screen one item at a time.
   Each control says what it is and what it does, with no "button" alone,
   no repeated name, and no unlabelled icon.
2. **The reading order makes sense.** The order matches the visual order and
   the meaning: heading first, content next, actions where the style guide
   puts them.
3. **Live regions are read once.** A banner, a loading label or a validation
   message is spoken once when it appears, and not again on every focus.

### The flows

The same flows as the keyboard tests, plus the screens they don't reach:

1. Server add → sign-in → register → home → create household.
2. Home: the drawer, the sections, a destination.
3. Create event, including the date and time pickers.
4. Game search, with the filter sheet.
5. Settings, and the feedback flow with its review screen.
6. The bootstrap error screen (stop the server, open the app).

### TalkBack (Android)

- Turn it on in Settings → Accessibility. Swipe right and left to move,
  double-tap to activate.
- Run the flows. Run each at the largest font size and display size.
- Check the reading-order and name checks with the reading controls set to
  "Controls", then again with "Headings".
- Check that opening the drawer, the filter sheet and a dialog announces a
  name for it.
- Check the focus hand-offs from #479 and #478 (below).

### VoiceOver (iOS and macOS)

- iOS: Settings → Accessibility → VoiceOver. macOS: Cmd+F5.
- Run the flows. On iOS, use the rotor for Headings and Form Controls: the
  filter sheet's range fields should read "Players, from" and the like, not
  "From" three times.
- On macOS, use VO+arrow to move and VO+Space to activate. Run the flows
  with the keyboard alone too.
- The drawer is named "Navigation menu" on iOS and macOS as elsewhere. The
  filter sheet and `AlertDialog` routes are unnamed there today
  (#762). Check that each is read as something.
- Check the focus hand-offs from #479 and #478 (below).

### A browser screen reader (web)

- VoiceOver in Safari, or NVDA with Firefox or Chrome on Windows.
- Turn Flutter's semantics on (the screen reader does it, or press the
  hidden "Enable accessibility" button) and run the flows.
- Move by Tab and by the reader's own commands. Compare: Tab should land on
  what the reader's form-control list shows.
- Check the focus ring after a mouse click closes a dialog opened from a menu
  by keyboard (see "What they don't cover").
- Press the arrows in the drawer and in the menus. They should move through
  the items (#661).

### Visual pass

The visual pass (colour, density, motion, text and display scaling on real
devices) is #170. It needs a device too, so it can share a session with this
one. It is not copied here.

### #70's list from #696

Check these on each platform's reader. #696's semantics were checked only in
Flutter's semantics tree under `flutter test`.

- **The offline strip** (`BgeOfflineStrip`, at the top of every route). It is
  read once when it appears. "Back online" is announced through the label
  change, and the collapse is silent. It isn't focusable. It sits in its own
  semantics container so a route's modal barrier doesn't hide it.
- **The unverified-session banner** (#98) gets the same container. A screen
  reader should reach it.
- **Busy controls** (`BgeInertButton`: the refresh banners' retry, the
  household member menu, the event poll's retry). While busy they should read
  as in progress, not as an available action, keep one node through the pass,
  and keep accessibility focus. On iOS they offer no focus action while busy.
- **Online-only controls while offline** (the `BgeOnlineOnly` family, about 30
  controls). The reason should be read as part of the control's name or hint.
  Menu items have it on a second line.
- **`BgeLoadingState` and `BgeEmptyState`.** The label, or the title and body,
  should be one live region, read once.

### Focus hand-offs from #479 and #478

On Android and iOS the navigator asks the platform to re-focus the last
accessibility-focused node when a route pops. After Leave, that node is the
removed list row. Check on TalkBack and VoiceOver whether accessibility focus
follows input focus to:

- the household list's heading, after Leave pops the detail;
- the member outcome banner's Dismiss, or the member-count heading, after
  Make owner or Remove;
- the leave-failure banner's Dismiss, after a failure disables the Leave row.

### #322's selection and copy checks

- **Pointer platforms** (macOS, Windows, Linux, native and in a browser): a
  global selection region sits above the router. Drag across body text and
  copy with Ctrl+C or Cmd+C: the text pastes whole. Chrome selects too: a drag
  across an app bar title and button labels copies their text joined. That is
  accepted, not a defect. Do this in Firefox on each desktop OS, as the
  platform is read from the browser.
- **Touch platforms** (Android and iOS, native and in a browser): there is no
  selection region, so long-pressing text selects nothing. That is correct.
  Check the explicit copy affordance instead: on the crash and feedback
  review, "Copy report" puts the whole report on the clipboard and says so.
  It isn't gated by platform, so check it wherever it ships, pointer
  platforms included.
  - The bootstrap error dialog and the server URL and version string have no
    copy affordance yet: the dialog drops the underlying error (#337) and no
    screen shows the URL or version (#336). #322 is where they were decided.
    Run this check on each once it ships.
- On touch, check that long-pressing over a button does not summon the text
  magnifier.

---

## 5. This run's results

Run 2026-11-05, for #50 and #644.

### The `textContrastGuideline` probe

The probe ran all three guidelines on `CreateHouseholdScreen` and
`GameBrowseScreen` (four games, thumbnails served and decoded; list and
thumbnails layouts), light and dark, at 390dp × 1.0, with the Ahem test font
and with the real fonts (Fraunces, Roboto, MaterialIcons). Neither mode gave
a false finding on either screen. A negative control (grey 0xFFCCCCCC on
white, 20px) failed `textContrastGuideline` in both modes, so the guideline
is live. The cover images were solid black with no text over them, so text
over a picture was not stressed.

**Decision:** `textContrastGuideline` kept, in Ahem mode, the first mode with
no false finding.

### Coverage

From `dart run tool/check_a11y_audit.dart`: 34 screens checked, 25 audited,
9 deferred. A screen with more than one test file is listed under the file
that holds its own audit. Home's four sections aren't `*_screen.dart`, so the
check doesn't count them; they are listed after the audited screens.

| Screen | Test file | Status |
|---|---|---|
| `AuthScreen` | `packages/features/auth/test/widgets/auth_screen_test.dart` | audited |
| `BootstrapErrorScreen` | `packages/app_shell/test/screens/shell_screens_test.dart` | audited |
| `CreateEventScreen` | `packages/features/events/test/widgets/create_event_screen_test.dart` | audited |
| `CreateHouseholdScreen` | `packages/features/household/test/widgets/create_household_screen_test.dart` | audited |
| `EditHouseholdScreen` | `packages/features/household/test/widgets/edit_household_screen_test.dart` | audited |
| `EventAvailabilityScreen` | `packages/features/events/test/widgets/event_availability_screen_test.dart` | audited |
| `EventGroupScreen` | `packages/features/events/test/widgets/event_group_screen_test.dart` | audited |
| `EventOverviewScreen` | `packages/features/events/test/widgets/event_overview_screen_test.dart` | audited |
| `FeedbackFlowScreen` | `packages/app_shell/test/screens/feedback_flow_screen_test.dart` | audited |
| `FeedbackReviewScreen` | `packages/app_shell/test/widgets/feedback_review_screen_test.dart` | audited |
| `GameBrowseScreen` | `packages/features/catalog/test/widgets/game_browse_screen_test.dart` | audited |
| `GameSearchScreen` | `packages/features/catalog/test/widgets/game_search_screen_test.dart` | audited |
| `HomePlaceholderScreen` | `packages/app_shell/test/screens/home_placeholder_screen_test.dart` | audited |
| `HomeScreen` | `packages/app_shell/test/screens/home_screen_test.dart` | audited |
| `HouseholdInviteListScreen` | `packages/features/household/test/widgets/household_invite_list_screen_test.dart` | audited |
| `InviteInboxScreen` | `packages/features/household/test/widgets/invite_inbox_screen_test.dart` | audited |
| `NotYetAvailableScreen` | `packages/app_shell/test/screens/shell_screens_test.dart` | audited |
| `RouteNotFoundScreen` | `packages/app_shell/test/screens/shell_screens_test.dart` | audited |
| `SendHouseholdInviteScreen` | `packages/features/household/test/widgets/send_household_invite_screen_test.dart` | audited |
| `SentInvitesScreen` | `packages/features/household/test/widgets/sent_invites_screen_test.dart` | audited |
| `ServerAddScreen` | `packages/features/server_onboarding/test/widget/server_add_screen_test.dart` | audited |
| `SettingsScreen` | `packages/app_shell/test/screens/settings_screen_test.dart` | audited |
| `ShellPlaceholderScreen` | `packages/app_shell/test/screens/shell_screens_test.dart` | audited |
| `SplashScreen` | `packages/app_shell/test/screens/shell_screens_test.dart` | audited |
| `StuckSyncOpsScreen` | `packages/features/sync/test/recovery/stuck_sync_ops_screen_test.dart` | audited |
| `UpcomingEventsSection` (home) | `packages/features/events/test/home/upcoming_events_section_test.dart` | audited |
| `StatsCard` (home) | `packages/features/collection/test/home/stats_card_test.dart` | audited |
| `NewestGamesSection` (home) | `packages/features/catalog/test/home/newest_games_section_test.dart` | audited |
| `SomethingToPlaySection` (home) | `packages/features/catalog/test/home/something_to_play_section_test.dart` | audited |
| `CollectionEntryScreen` | none | deferred, #708/#709/#735 |
| `DataGatewayDetailScreen` | none | deferred, #479/#478 |
| `DataGatewayFormScreen` | none | deferred, #479/#478 |
| `DataGatewayListScreen` | none | deferred, #479/#478 |
| `EventDetailScreen` | none | deferred, #508/#667 |
| `GameCollectionListScreen` | none | deferred, #708/#709/#735 |
| `GameDetailScreen` | none | deferred, #708/#709/#735 |
| `HouseholdDetailScreen` | none | deferred, #479/#478 |
| `HouseholdListScreen` | none | deferred, #479/#478 |

When those units merge, empty `_deferred` in `tool/check_a11y_audit.dart`,
write each screen's audit group and keyboard walk, and re-run this section.

### Live web pass

One pass on web with semantics on, against a local backend: Playwright
Chromium at 1280×900, light theme, macOS user agent, keyboard only. It walked
sign-in, register, home, the drawer, create household, events, create event
with its date and time pickers, game search with the filter sheet, and the
menus outside DataGateway. It also found that #661's arrow-key problem
reaches the home drawer, and that four `MenuAnchor` menus take the arrows,
Enter and Escape with semantics on and off.

### Findings

Each finding not fixed in the run is filed as an issue. Where a widget test
can express what the finding wants, that check is in the suite, skipped with
`skip: 'see #NNN'`, so the gap stays visible.

| Issue | Summary | Skipped check |
|---|---|---|
| #758 | Every list row (`ListTile`): the focused row's only indicator is the InkWell highlight, 1.27 to 1.40:1 against the resting row (WCAG 1.4.11) | `packages/ui/tokens/test/accessibility/bge_button_focus_ring_test.dart` |
| #759 | `SegmentedButton` segments get no #644 ring; only Material's focus overlay marks them | the same file |
| #760 | `FloatingActionButton.extended` gets no #644 ring; its focus overlay is 1.17:1 on its fill (five screens) | the same file |
| #761 | Drawer entries, filter chips and the date and time pickers show focus as a fill only, 1.14 to 1.40:1 | the same file, for the drawer entry and the filter chip |
| #762 | The filter sheet and every `AlertDialog` without `semanticLabel` have no accessible name on iOS and macOS | `packages/features/catalog/test/widgets/game_search_screen_test.dart`, for the sheet |
| #763 | Drawer entries read "Tab n of m" though the drawer is a launcher | `packages/app_shell/test/screens/home_screen_test.dart` |
| #764 | `TextButton()`, `OutlinedButton()` and `ElevatedButton()` clip their content to their shape once the ring's builder is set, so a label that wraps at 2.0 text loses glyph pixels at the curved ends | `packages/ui/tokens/test/accessibility/bge_button_focus_ring_test.dart` |
| #765 | Shift+Tab from the top of a lazily built list wraps to the last child still built, not the list's end: focus can't reach a child the list hasn't built | `packages/ui/widgets/test/layout/bge_page_test.dart` |

Fixed in this run, each with a regression test in the PR:

- `BgeInlineBanner`'s action, and so the refresh banner's retry, got no #644
  ring, because the banner replaces the button themes. It now gets one in the
  banner's foreground.
- Home's sections weren't audited. Each is audited in its own package now
  (§2).
- `BgePage` sorted content scrolled under the app bar above the back button,
  so Shift+Tab didn't walk Tab's order back. Its content is one traversal
  group now.
- The app drawer had no accessible name on iOS and macOS. It is named
  "Navigation menu" there, as Material names it elsewhere.
- The filter sheet's range fields were named only "From" and "To", three
  times each. Each now carries its range, as in "Players, from".
- `AuthScreen`'s server line was read twice, and its title was not a heading.
- A `BgePage` footer that scrolled within its cap broke Tab's order: Tab
  from its last control came back to its first. The footer is a traversal
  group of its own now.
- Tab scrolled a mid-page button flush against the viewport's edge, which
  clipped the last 4dp of its outside ring. Once focus brings a button into
  view, its ring now scrolls the rest of itself in.
- The feedback review's stack trace, one frame long, was a long-press target
  under 48dp tall. It now has the minimum height.

Two failures the guidelines report are not defects, and §3 describes both: a
disabled control's dimmed label, and a control clipped by the viewport's top
edge.
