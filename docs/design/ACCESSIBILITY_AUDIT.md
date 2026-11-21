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

The controls the theme can't reach are ringed in `ui`, and pinned there:

- **List rows** (#758): `packages/ui/widgets/test/focus/bge_row_focus_ring_test.dart`
  measures 3:1 between a focused row and the row at rest, outlined and plain,
  in all four themes. Each screen's suite checks its own rows ring on
  keyboard focus.
- **Extended floating action buttons** (#760):
  `packages/ui/widgets/test/buttons/bge_extended_fab_test.dart` measures the
  ring 3:1 against the button's fill in all four themes.
- **Rings over pictures** (#812): `packages/ui/widgets/test/images/bge_cover_tile_test.dart`
  measures the cover's and the badge's rings over a `primary` picture and a
  mid-grey one in all four themes, and the `ui` goldens draw both.
- **The same rule for all of them.** A mouse or trackpad press hides every
  ring, these included, until the next key press.
  `packages/ui/tokens/test/accessibility/bge_pointer_pressed_test.dart` pins
  the flag they share.
- **Kept that way.** `design_system_enforcement_test.dart` fails a tappable
  list tile outside `packages/ui` that doesn't pass the ring's
  `onFocusChange`, and a raw `FloatingActionButton.extended`.

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
  the Games tab's rows (#516): each is one merged node, its name, where it
  is played and who brings it, and its platform line speaks a comma where it
  draws a dot. Nor each Take back, which draws "Take back" and speaks "Take
  back" with its game's name. The same colour pairs are measured
  elsewhere on the page. Nor the Offer games page's rows, each one merged
  node, its title, where it is played and, where it can't be picked, why.
  There the reason a row can't be picked, in `bodySmall` and
  `onSurfaceVariant`, is held to 4.5:1 against the surface under it, light
  and dark, from the colours the widgets resolve, by
  `offer_games_screen_test.dart`. The title and platform line of such a
  row keep the disabled look, which WCAG 1.4.3 exempts, and are measured
  nowhere. Nor the Nominations section's rows (#517): each is one merged
  node, whose tally speaks commas where it draws dots, and each vote choice
  and Withdraw speaks its game's title beside its drawn word. Nor the Lineup
  sub-tab's rows (#519): each is one merged node, whose status line (what it
  is played as, who brings it, and Every date where it shows) speaks commas
  where it draws dots, and each Remove from lineup, Add to lineup and See in
  lineup speaks its game's title beside its drawn words.

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
4. Game search, with the filter sheet. Then open the quick look of a
   DataGateway result this server doesn't hold, tick an expansion and press
   Import (#713, #824): check the status ("Sending the import to the
   server…") is read and focus lands on it, that by keyboard it is ringed
   and Tab goes on from it rather than stopping on it again, and that the
   rows are read as one batch ("2 games in this import"), each saying its game
   and its state. Make an import fail or finish in part (stop a DataGateway,
   say): check the outcome is read once, as one banner, and that focus is
   still on it. Then close that quick look, restart the DataGateway if you
   stopped it, open the quick look of another result this server doesn't
   hold, press Import, and close the quick look before the import ends:
   check that no game page opens once it would have ended.
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
   search names them. Turn on Not mine and check your own rows leave. Open
   Filters (#851), choose a platform, and close it: focus is back on Filters,
   which reads "Filters (1)", a chip under the people's names the platform,
   and the count is read as it changes. Remove that chip with the reader's
   double-tap: focus goes to Filters. On an event with a game that has a
   subtitle, check its row, its Take back and its Nominate say it ("Catan:
   Seafarers"), and so do Nominate's dialog and its outcome. Take one of your
   games back and check the footer reads "… is off your games."
   Then stop the server, and on Details change your answer (Going to Maybe,
   say): the change fails, so the event is read again, and that read fails, so
   the games are read again, and fail too. Back on Games, check the footer
   also reads "Couldn't update the games. These may be out of date." under
   that outcome, and that both its Dismiss and its Try again are reached, by
   the reader and with Tab, at the largest text. Then, with the server back,
   take back a game that is nominated, or in the lineup for a date still to
   come (the server's 409), and check the footer reads "… is nominated, or in
   the lineup for a date still to come, so it can't come off your games yet.",
   and that its Dismiss is reached. Offline, check Offer games and each Take
   back say "Available when you're online" as their hint, and that it is drawn
   once, under Offer games. As someone who answered Not going, check Offer
   games is read as unavailable, with why as its hint.
   Then, online, press Offer games, and check the page is read as "Offer
   games", that each row is one item saying the game, where it is played
   and whether it is checked, and that a game you offered already reads
   "Already offered" and one added offline "Not synced yet", each as
   unavailable, with Tab passing over both. Type in the search and check
   the count ("3 games shown") is read as it changes. Open Filters, choose
   a platform, close it, and press Select all shown: it reads "Clear
   selection" and keeps focus. Search for something no game has, check "No
   games match" is read, and that Clear filters puts you on Filters, with
   no on-screen keyboard. Pick two games and press "Offer 2 games": back on
   the event, focus is on Offer games, which reads "Offering…" while the
   footer reads "Offering 2 games…", and then "2 games offered.". With ten
   or more picked, check the footer reads "Offering 10 games…" once, as the
   line appears, and nothing more until the outcome banner.
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
   Then, as host, the pool again (#518): every row has Take back, each
   naming its game ("Take back Azul"), and your own still goes without
   asking. On someone else's row it asks first: check the dialog reads
   "Take Azul off Ada's games?" and "Only they can offer it again.", that
   Take back is drawn as a destructive action, and that Keep it sends
   nothing and puts you back on Take back. Take back again and confirm:
   the row leaves, the footer reads "Azul is off Ada's games.", and the
   reader lands on the next row's Take back. On someone else's game that
   is nominated, check the footer names whose games it can't come off
   ("… so it can't come off Ada's games yet. …"). Then, as a household
   owner or admin who isn't on the roster of the household's event, check
   each row has Take back, with no Offer games, and that its dialog names
   the person whose game it is. Offline, check the Take back on someone
   else's row says "Available when you're online".
   Then, still as host, the Nominations section again (#518): a nomination
   awaiting approval has Approve and Reject, an open one Close vote, and a
   paused one neither, each naming its game ("Approve Catan", "Close the
   vote on Azul"). Each asks first. Check the Approve dialog reads "Approve
   Catan?" and "It goes into the lineup. Nothing can take it out yet.", the
   Reject dialog "Reject Catan?" and "This can't be undone." with Reject
   drawn as a destructive action, and the Close vote dialog "Close the vote
   on Azul?" with the row's tally, and the row's Interested line where it
   shows one ("2 for, 1 against, 0 interested so far. Interested counts as
   For. The result can't be undone."). Check Not yet sends nothing and puts
   you back on the button. Approve and confirm: the footer reads "Catan is
   approved and in the lineup." and the reader lands on the row, which now
   reads "Approved". Close a vote: the footer says how it came out, with the
   counts ("Azul passed: 2 for, 1 against. 3 of 4 counted."), and the row
   reads "Passed" alone. Then as a moderator, and as
   a household owner or admin who isn't on the roster of the household's
   event, check an open nomination has Close vote and one awaiting approval
   has no Approve or Reject. Offline, check each says "Available when
   you're online", and that the reason is drawn once under the row.
   Then the Lineup sub-tab (#519), with an event that has more than one
   date and games in the lineup for the whole event and for some of its
   dates. Check that Games opens on Lineup, the first of the three
   sub-tabs, that it reads "Loading the lineup" once, and that heading
   navigation finds "Every date", then each date, then "A date no longer
   on the event" where a game's date has gone. Each row is one item saying
   the game, then what it is played as ("Filler, up to 20 minutes"), who
   brings it, and "Every date" on a whole-event game under one date, read
   with pauses, not dots. Open a row's quick look: it is read as the game,
   its lines one item, with "Added from a nomination" where it came from
   one, and closing it puts you back on the row.
   Then the row of dates above the sub-tabs (#1042): it is read as
   "Dates", each date a button saying whether it is selected, Every date
   first. With the keyboard, Tab reaches each chip, and where the chips
   outrun the row, the row itself first, ringed; Left and Right on a chip
   move to the chip beside it, stopping at the ends, each brought into
   view (in a right-to-left language they swap); Alt+Left on a chip is not
   taken (on web it is the browser's Back). Choose a date: the lineup and
   the nominations show that date's first, then the event's own, marked
   "Every date". On a date that has started, Nominate on each pool row
   reads as unavailable with "Nominations for this date have closed" as its
   hint, and the same words are drawn once under it, on its row and in its
   quick look, where someone not going would have said "Whoever brings it
   isn't going".
   Then, as host, Add a game: the list is read as "Pick a game to add",
   each game one item, and one whose bringer isn't going reads as
   unavailable, saying why. Pick one: the dialog is read as "Add Catan to
   the lineup", asks the date where the event has no row of dates, then
   "Play it as" with Primary and Filler, Filler's "Minutes" with its hint
   ("The longest it should run…"), and the note. For a date that has
   started, check "This date has started, so a game added now can't be
   taken out of the lineup." is read before Play it as, and again as you
   choose that date in the dialog. Cancel puts you back on Add a game; add
   one, and the footer reads "Catan is in the lineup." and focus is back on
   Add a game. Under a host-only date, a pool row's main action is Add to
   lineup, read "Add Azul to the lineup", which goes back to it the same
   way. Then Remove from lineup: it reads "Remove Catan from the lineup"
   and asks first: check the dialog reads "Take Catan out of the lineup?"
   and its body, that Remove from lineup is drawn as a destructive action,
   and that Keep it sends nothing and puts you back on Remove. Confirm: the
   footer reads "Catan is out of the lineup." and the reader lands on the
   next row. On a game whose date has started, Remove reads as unavailable
   with "This game's date has started or was called off, so it can't be
   taken out of the lineup." as its hint, drawn once under it. Then, in the
   quick look of a nomination that passed, See in lineup reads "See in
   lineup: Catan" and opens the lineup game's quick look over it, read as
   the game; an outcome that lands there is read there once, and closing
   it puts you back on See in lineup without reading that outcome again.
   Offline, check Add a game, Add to lineup and Remove each say "Available
   when you're online". At the largest text and 320dp wide, check a long
   date's chip scales down to fit, and that the add dialog scrolls to its
   last field.
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
    - Server settings (#807), as an Owner or Admin: the Mail group's fields,
      then the connection security menu, and pick None to check the warning
      under it ("With no TLS, the password and every email cross the
      network unencrypted…") is read as it appears, with the focus staying
      on the menu. With a password saved, the line "A password is saved."
      with Change password and Remove password: press Change password and
      check focus lands on the new password field, with Keep saved password
      and Remove password beside it; press Keep saved password and check
      focus returns to Change password. Press Remove password, from either
      state, and check "The saved password will be removed when you save."
      is read, and focus lands on Keep password; press Keep password and
      check focus returns to Change password. Then change the host and Save
      with the password kept, and check the password field is asked for and
      takes focus. Save the mail group, and while the save is out (a slow
      connection helps), check the Registration and sign-in Save reads as
      unavailable with "Available when the save in progress finishes." as
      its hint, with no line drawn for it. Then Send test email: the button
      keeps focus while the test is out; "Test email queued for your
      address. Waiting…" is read, then the outcome. Send a second test that
      ends the same way and check the outcome is read again, not skipped as
      unchanged. Then edit a Mail field and check the outcome goes. Save a wrong password and send a
      test: the outcome is read with its title first, "Test email failed",
      then the reason (a test the server won't send is titled "Test email
      not sent"). With unsaved Mail changes, check the button reads as
      unavailable with its reason ("Save your changes first…") as its hint.
      In Registration and sign-in, pick Automatically, when both have verified the email,
      and check its warning is read.
    - Server settings as a Moderator, whose role reads the settings but
      cannot change them: the role reads every setting, so the entry is on
      the dashboard; open the section from it. The banner "Your role can
      view these settings but not change them." is read, every field reads
      as read-only, not as disabled, and there is no Save, no password
      button and no Send test email. Walk all six groups (General,
      Registration and sign-in, Mail, Invitations, Contributions, Data
      retention): every switch, menu and field reads as read-only, not as
      disabled, and no group has a Save.
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

### Focus hand-offs from #807

The same check, for the server settings screen. Each button below is
replaced by the control named, and focus is handed on, however it is pressed
(keyboard, tap or screen reader):

- Change password, replaced by the new password field.
- Keep saved password, beside that field: Change password.
- Remove password, from the saved state: Keep password; from beside the
  new password field: Keep password as well.
- Keep password: Change password.
- Save and the password buttons, taken away when the role's update access
  falls while the screen is open: the field just before them (the From
  address, or the password field, or the user name when no password
  button is shown). Save and Send test email likewise go to the From
  address, Mail's last field.
- The Registration and sign-in group's Save, taken away the same way: the
  "Linking a sign-in provider" menu.
- General's Save, taken away the same way: the server name.
- Invitations' Save, taken away the same way: the event policy menu.
- Contributions' Save, taken away the same way: the reclaim days.
- Data retention's Save, taken away the same way: the audit days while the
  audit switch is on, and the audit switch while it is off.
- Retry, on the screen's load failure: the heading.
- Send test email keeps focus while a test is out.

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
  pool, whether or not the read after it works: the next row's Take back,
  else the nearest one before it, else Offer games, else the search field.
  Only your own rows have one, unless you may take back anyone's game
  (#518). Nothing moves if focus went elsewhere while it was out, or if the
  take-back was refused and the row stays. If the games become hidden,
  nothing of the tab is left to take it, and it stays on the page.
- A person's chip under the search, removed: the chip that takes its
  place, else the one before it, else People. A chip removed by pointer
  while focus is on another chip moves no focus.
- A filter's chip under the people's (#851), removed: the chip that takes
  its place, else the one before it, else Filters, as on the page.
- Clear filters, in "No games match", however it is pressed: People, never
  the emptied search field, so no on-screen keyboard opens. Pressed by a
  pointer while keyboard focus sits on another control, it moves no
  focus.
- *Whose games*, closed: People. Filters' sheet, closed: Filters (#851).
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

### Focus hand-offs from #518

The same check, for Take back on someone else's row in the Games tab's
pool, as host, co-host or moderator, or as a household's owner or admin
on its event.

- Its dialog, closed by Keep it or by Back: Take back, which sends
  nothing.
- Its dialog's Take back: Take back, which keeps focus while the
  take-back is out, read as unavailable; then, its row gone, the next
  row's Take back, as #516's hand-off says.

And for a host's Approve, Reject and Close vote on a nomination's row,
each moving focus only if focus is then free, as #517's do:

- Its dialog, closed by Not yet or by Back: the button, which sends
  nothing.
- Its dialog's Approve, Reject or Close vote: the button, which keeps
  focus while the decision is out, read as unavailable; then, the row
  staying as decided and its buttons gone, the row itself, read as one
  item with its new status, as after a withdrawal. A decision refused or
  failed leaves focus on the button.
- A decision that takes its row out of the filter, as an approval under
  Awaiting approval does, or that finds the nomination gone: the first
  control of the next row shown, else of the row before it, else Filters,
  however it was pressed, the reader's double-tap included.

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
| `EventDetailScreen` | `packages/features/events/test/widgets/event_detail_screen_test.dart` (the Nominations section's rows, Filters and Sort among them, #517, and a host's Close vote dialog, #518), `packages/features/events/test/widgets/event_detail_tabs_test.dart`, for the Games tab's rows, controls and *Whose games* (#516), and the dialog that asks before someone else's game is taken back (#518), `packages/features/events/test/widgets/event_games_tab_test.dart`, for a nomination row and Withdraw at 320dp and 200% text (#517), and a host's Approve, Reject and Close vote with their dialogs (#518), `packages/features/events/test/widgets/event_nominations_section_test.dart`, for the vote control and its note dialog (#517), `packages/features/events/test/widgets/nomination_vote_control_test.dart` and, for who voted (#517), `packages/features/events/test/widgets/nomination_voters_sheet_test.dart` | audited |
| `EventGroupScreen` | `packages/features/events/test/widgets/event_group_screen_test.dart` | audited |
| `EventOverviewScreen` | `packages/features/events/test/widgets/event_overview_screen_test.dart` | audited |
| `FeedbackFlowScreen` | `packages/app_shell/test/screens/feedback_flow_screen_test.dart` | audited |
| `FeedbackReviewScreen` | `packages/app_shell/test/widgets/feedback_review_screen_test.dart` | audited |
| `GameBrowseScreen` | `packages/features/catalog/test/widgets/game_browse_screen_test.dart` | audited |
| `GameCollectionListScreen` | `packages/features/collection/test/widgets/game_collection_list_screen_test.dart` | audited |
| `GameDetailScreen` | `packages/features/catalog/test/widgets/game_detail_screen_test.dart` | audited |
| `GameSearchScreen` | `packages/features/catalog/test/widgets/game_search_screen_test.dart` | audited |
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
| #761 | Drawer entries and the date and time pickers show focus as a fill only, 1.14 to 1.40:1. No fill passes on a drawer entry (the decision is back with #414), the day grid has none, and the time dial never reports focus | `packages/ui/tokens/test/accessibility/bge_button_focus_ring_test.dart`, for the drawer entry |
| #909 | A focused *selected* bar or rail destination is under 3:1: the fill paints over its indicator, and no colour stands clear of that and carries both icons | `packages/ui/tokens/test/accessibility/bge_button_focus_ring_test.dart` for the bar, and `packages/app_shell/test/navigation/navigation_shell_test.dart` for the rail |
| #762 | The filter sheet and every `AlertDialog` without `semanticLabel` have no accessible name on iOS and macOS | `packages/features/catalog/test/widgets/game_search_screen_test.dart`, for the sheet |
| #763 | Drawer entries read "Tab n of m" though the drawer is a launcher | `packages/app_shell/test/screens/home_screen_test.dart` |
| #764 | `TextButton()`, `OutlinedButton()` and `ElevatedButton()` clip their content to their shape once the ring's builder is set, so a label that wraps at 2.0 text loses glyph pixels at the curved ends | `packages/ui/tokens/test/accessibility/bge_button_focus_ring_test.dart` |
| #765 | Shift+Tab from the top of a lazily built list wraps to the last child still built, not the list's end: focus can't reach a child the list hasn't built | `packages/ui/widgets/test/layout/bge_page_test.dart` |
| #1052 | `ExpansionTile` headers show focus only by their ink's tint, about 1.3:1: the event create form's "Advanced: rules" (`event_rules_section.dart`) and the feedback review's stack trace and breadcrumbs (`feedback_review_screen.dart`). The fix is a shared ringed expansion row in `ui` | none yet |

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

Fixed after the run, so no longer in the findings table:

- #758, fixed 2026-11-20: every tappable `ListTile`, `CheckboxListTile`,
  `SwitchListTile` and `RadioListTile` outside `packages/ui`, plain or
  outlined, sits in `BgeRowFocusRing`, a `focusOutlineWidth` ring on keyboard
  focus only. `ExpansionTile` headers don't yet (#1052, in the open findings above).
  The skipped check moved from `ui_tokens` to `packages/ui/widgets/test/focus/bge_row_focus_ring_test.dart`
  and passes.
- #759, fixed 2026-11-20: a focused `SegmentedButton` segment is filled 3:1
  from its rest, and its label changes with the fill, `onInverseSurface` in
  all four themes. It holds over the page, a sheet and a dialog, and under a
  hover (`bge_button_focus_ring_test.dart`).
- #761, filter chips fixed 2026-11-20: a chip's side draws a
  `focusOutlineWidth` ring, `primary` unselected. Selected, it is
  `onSecondaryContainer` in light, dark and high-contrast dark, where
  `primary` falls under 3:1 beneath the focus tint, and `primary` in
  high-contrast light. The drawer and the pickers stay open in the findings
  above. The chip's check moved into the chips' group and passes.
- #909, fallback fixed 2026-11-20: a palette where no fill passes now gets
  the closest one from `BgeFocusFill`, and its icon stays above 1:1. A
  focused *selected* destination stays open in the findings above.
- #760, fixed 2026-11-20: the six extended floating buttons are `BgeExtendedFab`,
  ringed inside the edge in a colour that holds 3:1 on the fill. The skipped
  check moved to `packages/ui/widgets/test/buttons/bge_extended_fab_test.dart`
  and passes.
- #812, fixed 2026-11-20, found in PR #809's review rather than this run: a
  one-tone ring could vanish on cover art close to `primary`. The cover's
  and the badge's rings now draw two tones 9:1 apart, which keeps one 3:1
  from any one colour beside them (`bge_cover_tile_test.dart`).
- #802, fixed 2026-11-19: `CollectionEntryScreen`'s
  Edit and Remove, `primary` text on the app bar's scrolled-under tint,
  measured 4.39:1 in light. The scrolled-under app bar no longer tints, so
  `primary` on it holds 4.88:1. A token test asserts it in all four themes
  (`bge_theme_test.dart`), and the audit call on `ready, scrolled to the end`
  in `collection_entry_screen_test.dart` is no longer skipped.

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
