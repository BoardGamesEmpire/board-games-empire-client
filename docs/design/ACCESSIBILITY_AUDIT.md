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
under `test/home/` in events, collection and catalog. Household detail's events
section, `HouseholdEventsSection`, is the same: it lives in events, which
household doesn't depend on, so household detail's audit hosts a stand-in, and
the section is audited in
`packages/features/events/test/household/household_events_section_test.dart`.

### The coverage check

`tool/check_a11y_audit.dart` (`melos run check:a11y-audit`, also in CI's
`test-files` job) fails when a `*_screen.dart` under a package's `lib/` has no
test in the same package holding both `group('accessibility audit'` and the
screen's class name. A new screen fails it until someone writes the group.
It prints the exempt screens when there are any. The match is a text match, so
it catches the screen nobody thought of, not a group that audits nothing. The
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
  leg walks the signed-in home through all four of its sections: the menu
  button, upcoming events' See all link and event card, the stats card (text
  only, so no stop), "Recently added"'s See all link and cover, and "Something
  to play"'s Reshuffle and cover. Then the open drawer, the household list
  (back, the row, Create household) and the create-household form, and it
  checks that Escape closes the drawer with focus back on its menu button.
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
- **Disabled controls.** The contrast guideline skips a node whose own
  flags say disabled, but a control merged into a bigger node that doesn't
  say so has its dimmed label measured. WCAG 1.4.3 exempts inactive
  controls, so a state with one passes `textContrast: false` and says why in
  a comment. The same controls pass in the state where they are enabled.
- **Clipped controls.** The tap-target guideline measures a control clipped
  by the viewport at its clipped size, so a scroll that leaves a field half
  under the top edge fails it, though nothing a user meets is wrong. Such a
  state is audited as a whole page in a tall view instead, as above.
- **Some pop-ups.** Household list and detail, the staff households list
  (its Show and Sort menus and Restore's confirm dialog), the three
  DataGateway screens, event detail, game detail and the two collection
  screens audit every dialog, sheet and menu they open. Elsewhere only
  home's drawer, game search's filter sheet, sent invites' filter menu and
  stuck changes' discard dialog are audited. The rest are not: the confirm
  dialogs of the invite inbox, the household's invite list and the
  bootstrap error screen, and create event's date and time pickers, among
  others. Nor is the game quick look, which a cover on home's rows or the
  browse screen opens: it is no screen of its own, so the coverage check
  doesn't ask for it (#803).
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
- **Text on event detail.** The vote chips, "Confirm this date", the
  tallies and the type and status line speak a label that differs from their
  drawn text, so the contrast guideline measures none of them there. Nor
  the Games tab's rows (#516): each is one merged node, its title, where it
  is played and who brings it, and its platform line speaks a comma where it
  draws a dot. Nor each Take back, which draws "Take back" and speaks "Take
  back" with its game's title. The same colour pairs are measured
  elsewhere on the page. Nor the Offer games page's rows, each one merged
  node, its title, where it is played and, where it can't be picked, why.
  There the reason a row can't be picked, in `bodySmall` and
  `onSurfaceVariant`, is held to 4.5:1 against the surface under it, light
  and dark, from the colours the widgets resolve, by
  `offer_games_screen_test.dart`. The title and platform line of such a
  row keep the disabled look, which WCAG 1.4.3 exempts, and are measured
  nowhere. Nor the Nominations section's rows (#517): each is one merged
  node, whose tally speaks commas where it draws dots, and each vote choice
  and Withdraw speaks its game's title beside its drawn word.

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
7. Event detail from Events: an answer, with its note and not-going dialogs,
   then as host the actions and date menus and the dialogs they open. Then
   a roster row's menu, with its Remove dialog and the Not going dialog for
   someone else. Check that each dialog names the person. Then Add people:
   the page's search, its role list and Add, and that focus is back on Add
   people once the page closes. Then the Games tab (#516): check the tabs
   read "Tab 1 of 2" and "Tab 2 of 2", that opening Games reads "Loading
   the games" once and then the pool, and that each row is one item saying
   the game, where it is played ("Tabletop, Physical") and who brings it.
   Type in the search and check the count ("2 games of 4") is read as it
   changes. Open People, check the pop-up is read as "Whose games", choose
   someone, and close it: focus is back on People, and the chip under the
   search names them. Turn on Not mine and check your own rows leave. Take
   one of your games back and check the footer reads "… is off your
   games." Then stop the server, and on Details change your answer (Going
   to Maybe, say): the change fails, so the event is read again, and that
   read fails, so the games are read again, and fail too. Back on Games,
   check the footer also reads "Couldn't update the games. These may be
   out of date." under that outcome, and that both its Dismiss and its Try
   again are reached, by the reader and with Tab, at the largest text. Then,
   with the server back, take back a game that is nominated, or in the
   lineup for a date still to come (the server's 409), and check the
   footer reads "… is nominated, or in the lineup for a date still to
   come, so it can't come off your games yet.", and that its Dismiss is
   reached. Offline, check Offer games and each Take back say "Available
   when you're online" as their hint, and that it is drawn once, under
   Offer games. As someone who answered Not going, check Offer games is
   read as unavailable, with why as its hint.
   Then, online, press Offer games, and check the page is read as "Offer
   games", that each row is one item saying the game, where it is played
   and whether it is checked, and that a game you offered already reads
   "Already offered" and one added offline "Not synced yet", each as
   unavailable, with Tab passing over both. Type in the search and check
   the count ("3 games shown") is read as it changes. Open Filters, choose
   a platform, close it, and press Select all shown: it reads "Clear
   selection" and keeps focus. Search for something no game has, check "No
   games match" is read, and that Clear filters puts you on Filters, with
   no on-screen keyboard. Pick two games and press "Offer 2 games": back on the
   event, focus is on Offer games, which reads "Offering…" while the
   footer reads "Offering 1 of 2…", and then "2 games offered.". With ten
   or more picked, check the footer's line is not read at every step and
   doesn't run on after the run has ended.
   With a banner showing above the tabs (stop the server and change your
   answer on Details: the change and the read of the event after it fail,
   and their banners show above the tabs), open Games, scroll the pool
   several screens down, then with TalkBack swipe back from the first row
   in view, and note
   whether focus jumps to the banner and whether the page scrolls. With
   VoiceOver, move focus to the banner by the rotor, and note whether the
   page scrolls to it.
   Then the Nominations section (#517), above the pool, with an event that
   has several nominations, one of them yours, and more than one date.
   Check that heading navigation finds "Nominations" and then "Games
   pool", that opening Games reads "Loading nominations" once, and that
   each row is one item saying the game, where it is played, who
   nominated it, whose copy it is, what it is for ("For the whole event"),
   where it stands ("Voting"), and its tally as words ("2 for, 1 against,
   0 interested"), then the Interested line and when voting closes where
   they show. A paused row says who isn't coming and what it goes back
   to. Under an open row, check the three vote choices each name the game
   ("For Catan"), that the one chosen reads as selected, that a choice
   pressed reads "…, saving your vote…" and keeps focus until it lands,
   and that the footer then reads "Your vote on Catan is in." Where your
   vote won't count yet, check the line above the choices ("Your vote
   counts once you say you're going.") is read before them. Check "Add a
   note" names the game, and its dialog. Open Who voted: the pop-up is
   read as "Who voted on Catan", a struck-through vote says it doesn't
   count, and closing it puts you back on Who voted. On your own live
   nomination, Withdraw reads "Withdraw Azul" and asks first; after it,
   the footer reads "You withdrew Azul." and the reader lands on the row,
   which now reads "Withdrawn". On a pool row, Nominate reads "Nominate
   Catan"; on an event with more than one date it asks which, a date
   nominated already reading "Already nominated" and unavailable, and one
   the game is in the lineup for reading "Already in the lineup"; after
   it, the footer reads "Catan is nominated. Voting is open." and the
   pool row reads "Nominated". Nominate on any copy of a game in the
   lineup for every choice reads "Already in the lineup" as its hint.
   Then the header: open Filters, check the pop-up is read as "Filters",
   with "Status" and "Date" as headings, each status chip saying whether
   it is selected, the dates as radio buttons with "Any date" chosen, and
   the Mine and Not voted yet switches. Choose Voting and close it: focus
   is back on Filters, a "Voting" chip shows, and the count ("2 of 5
   nominations") is read once as it changes. Open Sort ("Sort: Newest"):
   it says it is expanded, the current order reads as selected, and
   picking Most support puts focus back on Sort, read as "Sort: Most
   support", and reorders the rows. Turn on Not voted yet and vote on the
   first row: it leaves the list, and the reader lands on the next row's
   first vote choice. Choose filters that leave nothing, check "No
   nominations match" is read, and that Clear filters brings every
   nomination back and puts you on Filters. Switch to Details and back:
   the filters and the order are as you left them. At the largest text,
   check Filters, Sort, every chip and the count fit the screen, and that
   the Filters pop-up scrolls to its last switch with the keyboard up.
   Offline, check each vote choice and Withdraw say "Available when
   you're online", while Filters and Sort still work.
8. Game detail from Games, and a cover's quick look from a home row.
9. Collection: the list in both layouts, a stack's picker, and an entry with
   its edit sheet and remove dialog. Then the header: type in the search and
   check the count under the filters ("1 game of 3") is read as it changes;
   open Filters, choose a medium and flip a section, and check each chip
   reads its filter, a flipped one starting with "Not"; open the sort menu
   and check it says it is expanded, that the current order reads as
   selected, and that a pick returns focus to the sort button. Then search
   for something no game has, and check "No games match" is read and Clear
   filters brings the list back.
10. Admin, from the drawer: the dashboard, with an entry for each section
    the account may see, then each section from its entry.
    - The DataGateway list: a row's menu, the add form, and a DataGateway's
      detail with its language picker.
    - The staff households list: the search (one character first, whose
      hint says what a search needs, then a name), Show and Sort, a deleted
      household's Restore with its confirm dialog (Cancel, then Restore),
      and the outcome banner with its Dismiss. Then a live household's staff
      detail.
11. The invite inbox: a pending invite's Accept, then its Decline and the
    decline confirm dialog (Cancel, then Decline), and the outcome banner
    after each. No automated check opens this dialog (§3, "Some pop-ups").
12. A household's invite list: a row's Revoke and its confirm dialog, and,
    on an invite awaiting approval, Turn down and its dialog. Both dialogs
    have Cancel and the confirming button. Check the title and body say
    which of the two it is, and that focus returns to the row, or to
    where its removal leaves it, on dismiss. No automated check opens
    these dialogs either.

### TalkBack (Android)

- Turn it on in Settings → Accessibility. Swipe right and left to move,
  double-tap to activate.
- Run the flows. Run each at the largest font size and display size.
- Check the reading-order and name checks with the reading controls set to
  "Controls", then again with "Headings".
- Check that opening the drawer, the filter sheet and a dialog announces a
  name for it.
- Check the focus hand-offs from #479 and #478, from #684 and #685, from
  #715, and from #516 (below).

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
- Check the focus hand-offs from #479 and #478, from #684 and #685, from
  #715, and from #516 (below).

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
  household member menu, the event poll's retry, event detail's Add people
  while its own add is out, and its Games tab's Offer games while its own
  run of offers is out). While busy they should read as in
  progress, not as an available action, keep one node through the pass, and
  keep accessibility focus. On iOS they offer no focus action while busy.
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

### Focus hand-offs from #684 and #685

The same check, for the admin screens. The dashboard's return is #479's
case: the pop asks the platform to re-focus an entry that has gone.

- On the staff households list, Restore's row leaving (restored under
  Deleted, or turned live under All): the outcome banner's Dismiss, or the
  heading. So does a Restore whose row a read took while its confirm dialog
  was open, as the dialog closes.
- On the same list, Load more, gone with the last page: the first row that
  page brought.
- On the dashboard, an entry leaving as the account's access changes: the
  next entry, else the one before it, else the heading. Also on the way
  back from a section that covered the dashboard when its entry left, as
  when the section is refused and asks the access again.
- Retry, on the dashboard, the staff households list and the staff
  household detail: the heading.

### Focus hand-offs from #715

The same check, for Collection's header and the game search's filter
chips. Each control below leaves the screen once pressed, and input focus is
handed on:

- Clear filters, in Collection's "No games match", however it is pressed:
  the Filters button, never the emptied search field, so no on-screen
  keyboard opens. Pressed by a pointer while keyboard focus sits on another
  control, it moves no focus.
- A filter chip removed, on either screen, by the screen reader's activation
  of its remove button as by the keyboard: the chip that takes its place,
  else the one before it, else the Filters button. A chip removed by a
  pointer while keyboard focus sits on another control moves no focus.

### Focus hand-offs from #516

The same check, for the event screen's Games tab and its Offer games page.
A control that removes itself hands focus on after its own press, however
the press came: a key, a pointer, or the reader's double-tap, which moves
no input focus. It moves focus only if focus is then free: on nothing, on
the page, or still on the control that left. So with the reader, the
cursor should land on the control named below. A press while input focus
stays on another control moves nothing, but two kinds of press free focus
first, and then the hand-off moves it as expected:

- On desktop and the web, a mouse press on a chip while the search field
  has focus first takes focus off the field, so the chip's neighbour takes
  it.
- While one row's take-back is out, every other Take back is disabled, so
  one that held keyboard focus drops it. Once the pressed row has gone,
  focus goes on from that row, and can land back on the Take back that
  dropped it.

The hand-offs:

- Take back, its row gone as the server answers that the game is off the
  pool, whether or not the read after it works: the next of your rows'
  Take back, else the one before it, else Offer games, else the search
  field. Nothing moves if focus went elsewhere while it was out, or if the
  take-back was refused and the row stays. If the games become hidden,
  nothing of the tab is left to take it, and it stays on the page.
- A person's chip under the search, removed: the chip that takes its
  place, else the one before it, else People. A chip removed by pointer
  while focus is on another chip moves no focus.
- Clear filters, in "No games match", however it is pressed: People, never
  the emptied search field, so no on-screen keyboard opens. Pressed by a
  pointer while keyboard focus sits on another control, it moves no
  focus.
- *Whose games*, closed: People.
- The Offer games page, closed by its Offer button or by Back: Offer games,
  which keeps it, read as "Offering…", through the run it sent.
- On the page, Clear filters, in "No games match", however it is pressed:
  Filters, never the emptied search field. A filter chip removed: the chip
  that takes its place, else the one before it, else Filters. Select all
  shown keeps focus as it becomes Clear selection, and back.

### Focus hand-offs from #517

The same check, for the Games tab's Nominations section. Each hand-off
moves focus only if focus is then free, as #516's do, and a press however
it came arms it, the reader's double-tap included.

- Withdraw, its row staying as Withdrawn: the row itself, read as one
  item with its new status. Tab goes on from it, and it is no stop of its
  own afterwards.
- A vote or a withdrawal that takes its row out of the filter, as a vote
  under Not voted yet does, or a row that leaves the filter while it holds
  focus: the first control of the next row shown, else of the row before
  it, else Filters.
- Who voted, closed: Who voted.
- Filters, closed: Filters. Sort, an order picked or the menu closed:
  Sort.
- A filter chip removed: the chip that takes its place, else the one
  before it, else Filters. A chip removed by pointer while focus is on
  another control moves no focus.
- Clear filters, in "No nominations match", however it is pressed:
  Filters.
- Nominate, through its dialog and its nomination: Nominate, which keeps
  focus, read as unavailable once the row is nominated for everything it
  could be, until focus moves on.

### #850's list from #517

#850's device pass takes these too, from the same build: the Nominations
section was checked only in Flutter's semantics tree under `flutter test`,
at 320dp and 200% text.

- Flow 7, from "Then the Nominations section (#517)": the rows read as one
  item each, the vote choices and their in-progress label, Who voted and
  its pop-up, Withdraw and its dialog, Nominate and its dialog, Filters,
  Sort and the count, and the offline hints.
- "Focus hand-offs from #517": whether the reader's cursor lands where
  input focus is handed, the next row's vote after a vote under Not voted
  yet above all.
- The count under Filters and Sort ("2 of 5 nominations"): read once as
  each filter changes, and not again as the reader passes over it.
- A vote choice while its vote is out: it is held enabled, so it keeps
  focus, and reads "…, saving your vote…". Note whether the reader still
  offers it as an action to press.
- The header and the Filters pop-up at 320×640 with 200% text, on a phone,
  with every filter in use: each chip's label scales down rather than
  clips, and the pop-up scrolls clear of the keyboard.

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

Run 2026-11-05 for #50 and #644, completed 2026-11-06.

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

`dart run tool/check_a11y_audit.dart` checks every `*_screen.dart`, prints
how many it checked, and fails on any that is neither audited nor exempt.
A screen with more than one test file lists each file. Home's four sections
and household detail's events section aren't `*_screen.dart`, so the check
doesn't count them; they are listed after the audited screens.

| Screen | Test file | Status |
|---|---|---|
| `AddAttendeeScreen` | `packages/features/events/test/widgets/add_attendee_screen_test.dart` | audited |
| `AuthScreen` | `packages/features/auth/test/widgets/auth_screen_test.dart` | audited |
| `BootstrapErrorScreen` | `packages/app_shell/test/screens/shell_screens_test.dart` | audited |
| `CollectionEntryScreen` | `packages/features/collection/test/widgets/collection_entry_screen_test.dart` | audited |
| `CreateEventScreen` | `packages/features/events/test/widgets/create_event_screen_test.dart` | audited |
| `CreateHouseholdScreen` | `packages/features/household/test/widgets/create_household_screen_test.dart` | audited |
| `DataGatewayDetailScreen` | `packages/features/data_gateway/test/widgets/data_gateway_detail_screen_test.dart` | audited |
| `DataGatewayFormScreen` | `packages/features/data_gateway/test/widgets/data_gateway_form_screen_test.dart` | audited |
| `DataGatewayListScreen` | `packages/features/data_gateway/test/widgets/data_gateway_list_screen_test.dart` | audited |
| `EditHouseholdScreen` | `packages/features/household/test/widgets/edit_household_screen_test.dart` | audited |
| `EventAvailabilityScreen` | `packages/features/events/test/widgets/event_availability_screen_test.dart` | audited |
| `EventDetailScreen` | `packages/features/events/test/widgets/event_detail_screen_test.dart` (the Nominations section's rows, Filters and Sort among them, #517), `packages/features/events/test/widgets/event_detail_tabs_test.dart`, for the Games tab's rows, controls and *Whose games* (#516), `packages/features/events/test/widgets/event_games_tab_test.dart` and, for a nomination row and Withdraw at 320dp and 200% text (#517), `packages/features/events/test/widgets/event_nominations_section_test.dart` | audited |
| `EventGroupScreen` | `packages/features/events/test/widgets/event_group_screen_test.dart` | audited |
| `EventOverviewScreen` | `packages/features/events/test/widgets/event_overview_screen_test.dart` | audited |
| `FeedbackFlowScreen` | `packages/app_shell/test/screens/feedback_flow_screen_test.dart` | audited |
| `FeedbackReviewScreen` | `packages/app_shell/test/widgets/feedback_review_screen_test.dart` | audited |
| `GameBrowseScreen` | `packages/features/catalog/test/widgets/game_browse_screen_test.dart` | audited |
| `GameCollectionListScreen` | `packages/features/collection/test/widgets/game_collection_list_screen_test.dart` | audited |
| `GameDetailScreen` | `packages/features/catalog/test/widgets/game_detail_screen_test.dart` | audited |
| `GameSearchScreen` | `packages/features/catalog/test/widgets/game_search_screen_test.dart` | audited |
| `HomePlaceholderScreen` | `packages/app_shell/test/screens/home_placeholder_screen_test.dart` | audited |
| `HomeScreen` | `packages/app_shell/test/screens/home_screen_test.dart` | audited |
| `HouseholdDetailScreen` | `packages/features/household/test/widgets/household_detail_screen_test.dart` and `packages/features/household/test/widgets/household_detail_leave_test.dart` | audited |
| `HouseholdInviteListScreen` | `packages/features/household/test/widgets/household_invite_list_screen_test.dart` | audited |
| `HouseholdListScreen` | `packages/features/household/test/widgets/household_list_screen_test.dart` | audited |
| `InviteInboxScreen` | `packages/features/household/test/widgets/invite_inbox_screen_test.dart` | audited |
| `NotYetAvailableScreen` | `packages/app_shell/test/screens/shell_screens_test.dart` | audited |
| `OfferGamesScreen` | `packages/features/events/test/widgets/offer_games_screen_test.dart` | audited |
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
| `HouseholdEventsSection` (household detail) | `packages/features/events/test/household/household_events_section_test.dart` | audited |

`_deferred` in `tool/check_a11y_audit.dart` is empty, so the run prints no
exemption block.

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
| #802 | The app bar's Edit and Remove on `CollectionEntryScreen`, `primary` text on the app bar's scrolled-under tint: 4.39:1 against 4.5 (light, once content scrolls under the bar) | `packages/features/collection/test/widgets/collection_entry_screen_test.dart`, `ready, scrolled to the end` |

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
- Event detail's link, a `SelectableText` like that stack trace, was a
  long-press target 42dp tall. It now sits in a box at least 48dp tall
  (`event_detail_sections.dart`), with a regression test in
  `event_detail_screen_test.dart`.
- At 320dp × 2.0 in SF Pro, the iOS and macOS font, "Add data gateway" and
  "Create household" made their floating buttons wider than the window,
  pushing the buttons' start edges 12dp and 8dp off screen. The guidelines
  don't check that a control stays on screen, and the test font draws every
  glyph an em wide, so its widths aren't a device's. A real-font render
  found it, and no suite runs one. The five extended buttons' labels are now
  `BgeFabLabel`, which scales a label down to the room the window leaves
  (`bge_fab_label_test.dart`).

Two failures the guidelines report are not defects, and §3 describes both: a
disabled control's dimmed label, and a control clipped by the viewport's top
edge. The first reached the data gateway form's Add button and event detail's Add
a date, answer chips and Add a note while a write is in flight:
`BgeOnlineOnly` merges the control's semantics, and online the merged node
carries no enabled state of its own, so the guideline measures its dimmed
label. Those states pass `textContrast: false`; the enabled controls pass
with contrast on. Offline the merged node now says disabled itself
(`bge_online_only.dart`), so the offline states of those screens, the
gateway detail and the household invite screens audit contrast too.
