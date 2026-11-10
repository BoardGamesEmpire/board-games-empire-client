# game_filters

The controls a list of games is narrowed with (#474, #715): the filter sheet,
its range fields, the Filters button that opens it, and the chips under a
list's search field that name the filters in use and clear them. The labels
they name games' facts with live here too, and the catalog labels its own
facts with them, so a filter reads as the fact it matches.

Two screens call it. The game search (`game_catalog`'s `GameSearchScreen`)
uses the default options. The collection list (`game_collection`'s
`GameCollectionListScreen`, #715) turns on `medium`, `missingBaseGame` and
`exclusion`, and passes the same options to the sheet, the chips and the
count. The sheet moved here from the game search unchanged so that the
collection's filters, and later an event's game picker (#516), build from it
rather than copy it.

## Why a shared feature package

Features don't depend on each other: `app_shell` depends on features, never
the reverse. There are two exceptions, `user_search` and this package, each a
piece of UI more than one feature draws. To stay safe to share, this package
may depend on `flutter`, `flutter_localizations`, `intl`, `models`, `ui` and
`ui_tokens` and nothing else: no feature, no bloc, no `interfaces` and no
`network_interface`. It uses all six; from `ui`, only `focusIsFree`, the
shared rule for focus whose control has left.

So it reads no data and holds no filter of its own past the sheet's edits.
The caller keeps a `CollectionFilter` from `models`, hands it to the sheet
and the chips, and applies what they hand back. The game search sends
`CollectionFilter.game`, the part the server can narrow by, and drops the
rest.

## Shape

- `showGameFilterSheet` — opens the sheet on `initial` and calls `onChanged`
  with the whole filter after every edit. There is no Apply button. A range
  that still holds bounds as the sheet closes commits them then, and
  `onChanged` gets that filter once the frame ends, so a caller may call
  `setState` from it. A range that closes with the sheet on bounds it can't
  send is dropped, and `onDropped`, or a SnackBar on the opener's messenger
  without one, says why.
- `GameFilterOptions` — which sections the sheet offers. The defaults are the
  game search's: `searchContentTypes`, `searchPlatformTypes`, and the
  server's highest bound, `defaultMaxRangeBound`. `medium`,
  `missingBaseGame` and `exclusion`, off by default, are for the collection
  (#715): a Medium section, a switch keeping only the expansions missing
  their base game, and a switch under each section that flips it to leave
  out what it matches. A flip goes with its section's last choice.
- `GameFiltersButton` and `gameFiltersInUseCount` — the button that opens the
  sheet, counting the filters in use, with an optional `focusNode` for a
  caller that sends focus to it. Pass the count the same `options` the
  chips get, so it counts exactly the chips.
- `GameFiltersInUse` — a chip for each filter in use, which clears it; a
  flipped filter's chip starts with "Not". A chip's removal, by keyboard,
  pointer or a screen reader's activation, hands focus to the chip that
  takes its place, else the one before it, once the caller has applied the
  filter it sent. The last chip calls `onEmptied` instead, for the caller to
  focus a control of its own, such as its Filters button
  (`GameFiltersButton.focusNode`). Focus moves only if it is free then: on
  nothing, on the page, or still on the chip that left. So a pointer's
  removal while keyboard focus sits on another control moves nothing. A
  removal the caller doesn't apply is dropped at the filter's next change.
  Keep the widget in the tree while it is empty: it draws nothing then, and
  needs to be there to call `onEmptied`.
- `InUseChips` — the row of removable chips `GameFiltersInUse` is drawn
  with, and its focus hand-off, for a caller whose chips name something
  else that narrows a list, as an event's Games tab names the people chosen
  (#516). The caller gives each chip its id, key, label and the value its
  removal leaves, and removes what the chip names in `onRemove`.
- `GameFilterKeys` — the keys on all of the above, for a caller's tests.
- `SearchRangeField`, `GameLengthBand`, `GameFilterChipLabel`, and the label
  helpers in `game_facts.dart` (`GameFact`, `contentTypeLabel`,
  `platformTypeLabel`, `mediumLabel`, `playersFact`, `playTimeRangeFact`,
  `yearText` and the rest).

## Server bounds

The range fields refuse what the server won't take: a bound outside an
int32, fewer than one player, a negative play time. Those bounds belong to
`network_interface`'s `GamesRemoteDataSource`, which this package can't
import, so `GameFilterOptions` writes them as literals.
`game_catalog`'s `test/search/game_filter_bounds_test.dart`, in a package that
depends on both, holds the two together.

## i18n

All copy comes from `GameFiltersLocalizations` (gitignored, regenerated —
`melos run generate`). `app_shell` registers its delegate, and a widget test
of a screen that draws any of this package's widgets, or the catalog's facts,
adds it to its own delegates.
