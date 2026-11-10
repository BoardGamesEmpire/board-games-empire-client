# game_filters

The controls a list of games is narrowed with (#474, #715): the filter sheet,
its range fields, the Filters button that opens it, and the chips under a
list's search field that name the filters in use and clear them. The labels
they name games' facts with live here too, and the catalog labels its own
facts with them, so a filter reads as the fact it matches.

Today the game search (`game_catalog`'s `GameSearchScreen`) is its one caller.
The sheet moved here from that screen unchanged so that the collection's
filters (#715), and later an event's game picker (#516), can build from it
rather than copy it.

## Why a shared feature package

Features don't depend on each other: `app_shell` depends on features, never
the reverse. There are two exceptions, `user_search` and this package, each a
piece of UI more than one feature draws. To stay safe to share, this package
may depend on `flutter`, `flutter_localizations`, `intl`, `models`, `ui` and
`ui_tokens` and nothing else: no feature, no bloc, no `interfaces` and no
`network_interface`. Today it needs all of them but `ui`.

So it reads no data and holds no filter of its own past the sheet's edits.
The caller keeps a `CollectionFilter` from `models`, hands it to the sheet
and the chips, and applies what they hand back. The game search sends
`CollectionFilter.game`, the part the server can narrow by, and drops the
rest.

## Shape

- `showGameFilterSheet` — opens the sheet on `initial` and calls `onChanged`
  with the whole filter after every edit. There is no Apply button. A range
  that closes with the sheet on bounds it can't send is dropped, and
  `onDropped`, or a SnackBar on the opener's messenger without one, says why.
- `GameFilterOptions` — which sections the sheet offers. The defaults are the
  game search's: `searchContentTypes`, `searchPlatformTypes`, and the
  server's highest bound, `defaultMaxRangeBound`. `medium`,
  `missingBaseGame` and `exclusion` are declared for the collection (#715)
  and not acted on yet.
- `GameFiltersButton` and `gameFiltersInUseCount` — the button that opens the
  sheet, counting the filters in use.
- `GameFiltersInUse` — a chip for each filter in use, which clears it.
- `GameFilterKeys` — the keys on all of the above, for a caller's tests.
- `SearchRangeField`, `GameLengthBand`, `GameFilterChipLabel`, and the label
  helpers in `game_facts.dart` (`GameFact`, `contentTypeLabel`,
  `platformTypeLabel`, `playersFact`, `playTimeRangeFact`, `yearText` and the
  rest).

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
