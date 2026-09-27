# game_collection

The game collection feature. Today it holds the hydrate (#259); the list
screen (#44) builds here next.

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

## Reading the list

`GameCollectionRepository.watchCollectionListItems()` streams the entries with
their title, subtitle, platform name and thumbnail, and re-emits when a
hydrate refreshes any of them.
