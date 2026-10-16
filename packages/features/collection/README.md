# game_collection

The game collection feature: the hydrate (#259) and the list screen (#44).

The directory is `features/collection`, but the package is `game_collection`:
`collection` is dart-lang's `package:collection`, already in the workspace's
dependency graph.

## The hydrate

`GameCollectionHydrator` pulls the user's collection from the server into the
local cache. `GameCollectionHydrateInstaller` starts it, unawaited, whenever a
user session activates, on native and web alike, and registers it with the
session's `SessionRehydrator` so a pass that started offline runs again later.

Each server row carries a summary of its platform game and game. The hydrator
writes that summary first (`GameRepository.cachePlatformGameSummaries`), then
the entry (`GameCollectionRepository.mergeFromServer`). The order matters: the
local collection row has an enforced foreign key onto its platform game, so on
a fresh device the entry alone cannot be stored.

`mergeFromServer` leaves any dirty or local-only entry alone, tombstones
included, so a hydrate never overwrites a change the sync queue has yet to
send.

The class docs carry the rest: the drain and its one catch-up pass, why the
catch-up is dated from the server's clock, and why nothing here may throw.

The installer also publishes what the pass is doing, as a
`GameCollectionHydrationStatus`, and a `GameCollectionRefresher` that runs one
more pass on demand. The list reads the first and its retry calls the second.

## The list

`GameCollectionRepository.watchCollectionListItems()` streams the entries with
their title, subtitle, platform name and thumbnail, and re-emits when a
hydrate refreshes any of them.

`GameCollectionListScreen` shows that stream. Its `GameCollectionListBloc`
combines it with the hydration status, so an empty cache that is still filling
shows a spinner rather than "no games yet", and a failed refresh shows a
banner over the rows the cache still holds until a pass completes. The
status carries which passes completed or failed, so a list opened mid-pass
still knows. The shell passes in the
repository, the status, the retry and an entry trigger; the screen resolves
nothing itself.

The list body is `GameCollectionListSliver`, separate from the page, so a
two-pane layout can host it under its own app bar.

Thumbnails load with `Image.network` and are cached in memory only (#449). On
web they fall back to an HTML image element when the image host sends no CORS
header, which BoardGameGeek's does not.

Run `melos run generate` once after checkout: the localizations under
`lib/l10n/` are generated and gitignored.
