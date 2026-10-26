# game_catalog

The game catalog feature (#42): browse the server's games, search them and
its DataGateways, open one game, and import a game the server doesn't hold
from a DataGateway (#43).

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

## Import

A DataGateway result the server doesn't hold imports from the search (#43).
The shell opens `GameImportDialog` from the search's `onImport`, and the
dialog's `GameImportBloc` sends `POST /api/games/import`, then polls
`GET /api/games/import/:batchId`.

One import is one base game, with no expansions and no locale: several at
once is #595, and a language is #594. The dialog polls every 2 seconds. The
server sets no deadline, so after 90 seconds, counting the time each poll
takes, the dialog says the import is still running. That isn't a failure: "Check again" polls the same
batch and starts nothing. The base game's job decides how the import ended,
not the batch's rollup. A failed job shows copy for its error code, and a
status this client doesn't know keeps polling. A poll that got no answer
keeps polling too, while a 403 or an unknown batch ends the import.

Each attempt has its own `correlationId`, a UUID v4, the only form the server
accepts. A start whose answer never came keeps its id, so trying again sends
the same one. For now the server starts a second batch anyway, which does no
harm because importing a game again updates it. Once backend#900 keys import
jobs on the correlation id, the same id will find the batch the server may
already have queued. A start the server answered drops its id, so trying
again after a failure takes a new one.

When the base game's job completes, the dialog closes with the game's id and
the shell opens the game's detail in its place. Closing the dialog first
stops the polling and opens nothing. The server finishes the import anyway,
and the next search shows the game as one it holds. Following an import after
its dialog closes is #596.

Nothing is cached here. The detail caches the game it reads, for this user,
as it does any game it opens. The poll's platform games are read but unused:
adding to a collection (#45) starts from the detail, once `GET /games/:id`
sends them (backend#791).

## Detail

`GameDetailBloc` reads `GET /api/games/:id` and caches the game. It lists the
game's platform games once the server sends them (backend#791); until then the
list is empty. Adding one to the collection is #45's, through a callback the
shell passes in.

A 404 or a 403 means this user can't read the game, so the bloc also forgets
it on this device for them (`GameRepository.forgetGame`), and offline browse
and search stop listing it. Then it tells `onGone`, and the shell tells every
catalog list open: the one the game was opened from, and a browse beneath a
search. Each takes the game down, whether that list came from the server or
from this device, and keeps it down while that screen is open. A detail
closed before the server answers tells no one: the answer may come after a
sign-out, and the lists open then may be the next user's.

## Screens

`GameBrowseScreen`, `GameSearchScreen`, `GameDetailScreen` and
`GameImportDialog` each own their bloc; the shell passes in the remote, the
cache and the callbacks, and the screens resolve nothing themselves.

The detail screen renders the description as Markdown with
`flutter_markdown_plus` (#472): GitHub's extensions, raw HTML never rendered,
and only `http`, `https` and `mailto` links, opened outside the app through
`url_launcher`. The package was picked with a probe against the pinned
Flutter, which showed that it has no HTML rendering path and that every link
tap reaches one callback.

Run `melos run generate` once after checkout: the localizations under
`lib/l10n/` are generated and gitignored.
