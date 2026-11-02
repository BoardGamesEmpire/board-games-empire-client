# game_collection

The game collection feature: the hydrate (#259), the list screen (#44) and the
add sheet (#45).

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
repository, the status, the retry, an entry trigger and, where there is a
catalog, a browse action the empty state offers (#45); the screen resolves
nothing itself.

The list body is `GameCollectionListSliver`, separate from the page, so a
two-pane layout can host it under its own app bar.

Thumbnails load with `Image.network` and are cached in memory only (#449). On
web they fall back to an HTML image element when the image host sends no CORS
header, which BoardGameGeek's does not.

## The add

`showAddToCollectionSheet` opens a modal bottom sheet that adds one platform
game to the collection (#45). The shell opens it from a game's detail, handing
over the session's repository and sync sender, the game and the platform game.
Its `AddToCollectionBloc` writes through
`GameCollectionRepository.addToCollection`, which queues the add for the server,
then sends the queued op at once with `sendNow`, as every write that queues one
does (see the sync queue's README). A send that doesn't get through leaves the
add queued, and the SnackBar after the sheet closes says whether the server has
it, hasn't got it yet, or refused it. The sheet can be dismissed while the send
runs: the add goes on, and its SnackBar shows once it settles. The bloc also
looks up the live entry already on the medium chosen, so the sheet can say what
the add makes.

Copies are typed or stepped with the minus and plus buttons beside the field,
from 1 up to what the server can store.

The platform game must already be cached: the entry has an enforced foreign key
onto its row, which the catalog's detail writes when it shows the game.

A rating left at "No rating" and a comment left blank are sent as none, so an
entry removed and added again keeps its old ones. The class docs on
`AddToCollectionSheet` and the bloc carry the rest.

Run `melos run generate` once after checkout: the localizations under
`lib/l10n/` are generated and gitignored.
