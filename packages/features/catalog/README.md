# game_catalog

The game catalog feature (#42): browse the server's games, search them and
its DataGateways, and open one game.

The directory is `features/catalog`, but the package is `game_catalog`, to
sit beside `game_collection`.

## Browse

`GameBrowseBloc` pages `GET /api/games`, in the server's order: by title, then
by id. Every page is written to the games cache as it arrives.

A 403 says this user may not read the server's games at all, and the screen
says so rather than showing the cache. On a later page it takes down the
pages already shown, too. When the first page cannot be fetched
for any other reason, the bloc reads the cache a page at a time in that same
order (`GameRepository.getGamesPage`) and says the list came from this device.
A retry keeps those rows up while it asks the server again, and keeps them if
it fails.

## Search

`GameSearchBloc` reads one page of `GET /api/games/search`. The server waits
for every DataGateway, for up to 15 seconds, so a search can take that long.
There is no "load more": the search has no stable order and no has-more
signal yet (backend#792). Streaming over the WebSocket is #473.

Results come in two sections: what this server holds, then what its
DataGateways found that the first section does not already list. A
DataGateway is named only when the user may read DataGateways; otherwise its
results carry no source name. DataGateways that did not answer are noted under
the results, by name where the user may read them and counted otherwise, so a
missing source does not read as one that found nothing.

The search can be narrowed by content type. The bloc and the data layer take
platform types too; offering them on screen is #474.

When the server's search fails, the bloc searches the games cached on this
device instead (`GameRepository.searchGames`). The cache holds no platform
types, so a search narrowed by one finds nothing there. A 403 is a refusal,
not a failure: the screen says the user has no access, as browse does.

## Detail

`GameDetailBloc` reads `GET /api/games/:id` and caches the game. It lists the
game's platform games once the server sends them (backend#791); until then the
list is empty. Adding one to the collection is #45's, through a callback the
shell passes in.

A 404 or a 403 means this user can't read the game, so the bloc also forgets
it on this device for them (`GameRepository.forgetGame`), and offline browse
and search stop listing it. Leaving the screen then pops `true`, and the
browse or search list it was opened from takes its row down, whether that
list came from the server or from this device.

## Screens

`GameBrowseScreen`, `GameSearchScreen` and `GameDetailScreen` each own their
bloc; the shell passes in the remote, the cache and the callbacks, and the
screens resolve nothing themselves.

The detail screen renders the description as Markdown with
`flutter_markdown_plus` (#472): GitHub's extensions, raw HTML never rendered,
and only `http`, `https` and `mailto` links, opened outside the app through
`url_launcher`. The package was picked with a probe against the pinned
Flutter, which showed that it has no HTML rendering path and that every link
tap reaches one callback.

Run `melos run generate` once after checkout: the localizations under
`lib/l10n/` are generated and gitignored.
