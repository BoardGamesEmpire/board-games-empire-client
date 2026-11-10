## 0.0.1

* Initial release (#715): the sheet a list of games is narrowed with, its
  range fields, the Filters button and the chips naming the filters in use,
  for the game search and any other feature to build from.
  `showGameFilterSheet` edits a `CollectionFilter` of the caller's and hands
  each change back, and `GameFilterOptions` says which sections it offers:
  the content types, platform types and ranges the game search has, and,
  where a caller asks, a Medium section, a switch that keeps only the
  expansions shown without their base game, and a switch per section that
  leaves out what it matches. `GameFiltersInUse` hands focus on when a chip
  is removed, to the next chip or to the caller's own control. The labels
  the sheet and the chips share with the catalog's facts live here too.
