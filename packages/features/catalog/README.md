# game_catalog

The game catalog feature (#42): browse the server's games, search them and
its DataGateways, open one game, and import a game from a DataGateway, with
the expansions the user chooses for it (#43, #713).

The directory is `features/catalog`, but the package is `game_catalog`, to
sit beside `game_collection`.

## Browse

`GameBrowseBloc` pages `GET /api/games`, in the server's order: by title, then
by id. Every page is written to the games cache as it arrives.

A 403 says this user may not read the server's games at all, and the screen
says so rather than showing the cache. The bloc also forgets this user's
catalog on this device, so offline browse and search show only games their
collection reaches (#557). On a later page it takes down the pages already
shown, too. When the first page cannot be fetched for any other reason, the
bloc reads the cache a page at a time in that same order
(`GameRepository.getGamesPage`) and says the list came from this device. A
retry keeps those rows up while it asks the server again, and keeps them if
it fails.

## Search

`GameSearchBloc` reads one page of `GET /api/games/search`. The server waits
for every DataGateway, for up to 15 seconds, so a search can take that long.
There is no "load more": the search has no stable order and no has-more
signal yet (backend#792).

Where the session has a `GameSearchStreamSource`, the screen opens one channel
on the session's socket and the bloc follows it, so this server's results
show as they arrive instead of waiting on the DataGateways (#473). A server
with no socket, or a socket that can't serve the search, searches over REST
as above.

Results come in two sections: what this server holds, then what its
DataGateways found that the first section does not already list. A
DataGateway is named only when the user may read DataGateways; otherwise its
results carry no source name. DataGateways that did not answer are noted under
the results, by name where the user may read them and counted otherwise, so a
missing source does not read as one that found nothing.

The search can be narrowed by content type. The bloc and the data layer take
platform types too; offering them on screen is #474.

The filter sheet, its Filters button and the chips naming the filters in use
come from `game_filters`, the feature package the catalog shares them through
(#715), and so do the labels the catalog's facts are made of. The search
holds its `GameSearchFilter` in its bloc and hands the sheet a
`CollectionFilter` wrapping it.

When the server's search fails, the bloc searches the games cached on this
device instead (`GameRepository.searchGames`). The cache holds no platform
types, so a search narrowed by one finds nothing there.

A 403 is a refusal, not a failure. On a search that asked the DataGateways,
it may be only the DataGateways that are refused (#795), so the bloc asks
once more without them. If that answers, the screen shows this server's
games, with the server's explanation where the DataGateways' results would
be, and the session's later searches leave them out from the start
(`DataGatewaySearchGrant`). A signed-out session leaves them out from its
first. A second 403, or one on a search that left them out, means the user
may not read the server's games at all: the screen says so, as browse does.
That refusal forgets this user's catalog on this device, and offline search
then shows only games their collection reaches (#557).

## Import

A search result opens a quick look over the search, not an import (#713).
A DataGateway result the server doesn't hold opens `SearchHitQuickLook`,
drawn from the hit alone: no route reads one game from a DataGateway. One
the server holds opens `GameQuickLook`, read by its game id, as a result
from this server does.

A DataGateway result's quick look offers Import, or Re-import for a game the
server holds, in a `GameImportPanel`, but only where the session may
`create` on `Game`, read as the quick look opens. Without that, the quick
look is information only. The panel lists the game's expansions at its
DataGateway to tick (`GET /api/games/search/expansions`), but only while the
session may ask the DataGateways: it shares the search's
`DataGatewaySearchGrant`, so a refusal either meets is kept for both.
Otherwise Import takes the game alone. An import is a direct write, so its
button waits for the connection; opening the quick look and reading the
expansions are reads, and don't.

Pressed, the button and the checklist give way to `GameImportProgress`, in
place, over the panel's `GameImportBloc`. The bloc sends
`POST /api/games/import` with the ticked expansions, then polls
`GET /api/games/import/:batchId` every 2 seconds until every job in the
batch has ended (#824). If the game needs a base game the server doesn't
hold, the server adds one to the batch (backend#971), and the progress says
which game needed it. The server sets no deadline, so after 90 seconds, 30
more for each job after the first, and at most 10 minutes, counting the
time each poll takes, the progress says the import is still running. That
isn't a failure: "Check again" polls the same batch and starts nothing.

The import ends when no job is pending or running (#824). A job in a
status this client doesn't know keeps the polls going too, even once the
requested game's own job has failed: the server cancels only the pending
jobs that needed it, and a running one goes on. A poll that got no answer
keeps polling, while a 403 or an unknown batch ends the import. Once every
job has ended, a requested game that failed or was cancelled fails the
import, with copy for its error code, and so does one that has when the
deadline passes. A requested game that was imported completes it, or
completes it in part where another game in the batch wasn't, and the
progress says how many. A failure or a part completion shows as a banner in
the status's place, which keeps the status's focus; Check again and Try
again stay in place, inert, through the poll or the start they began.

One import asks for one game, with the expansions ticked and no locale:
several games at once is #595, and a language is #594.

Each attempt has its own `correlationId`, a UUID v4, the only form the server
accepts. A start whose answer never came keeps its id, so trying again sends
the same one. For now the server starts a second batch anyway, which does no
harm because importing a game again updates it. Once backend#900 keys import
jobs on the correlation id, the same id will find the batch the server may
already have queued. A start the server answered drops its id, so trying
again after a failure takes a new one.

When the import completes, the panel hands the game's id to the search's
`onOpen`, once, from the quick look's own context. The shell pushes the
game's page over the quick look, which removes itself once the page has
arrived, so back from the page lands on the search. An import completed in
part opens the game only when the user asks. One that completes while a
dialog covers the quick look opens the game once the dialog has closed.
Closing the quick look, or the router dropping it, stops the polling and
opens nothing. The server finishes an import anyway, and the next search
shows the game as one it holds. Following an import after its quick look is
gone is #596.

Nothing is cached here. The detail caches the game it reads, for this user,
as it does any game it opens. The poll's platform games are read but unused:
adding to a collection (#45) starts from the detail, which reads them from
`GET /games/:id` (backend#791).

## Detail

`GameDetailBloc` reads `GET /api/games/:id` and caches the game, then its
platform games: full records the server sends with it (backend#791), which the
detail lists. Adding one to the collection is #45's, through a callback the
shell passes in, which is handed the game and the platform game. The cached
row is what the add's foreign key needs. Offline, the detail shows the cached
game with no platform games.

A 404 or a 403 means this user can't read the game, so the bloc also forgets
it on this device for them (`GameRepository.forgetGame`), and offline browse
and search stop listing it. Then it tells `onGone`, and the shell tells every
catalog list open: the one the game was opened from, and a browse beneath a
search. Each takes the game down, whether that list came from the server or
from this device, and keeps it down while that screen is open. A detail
closed before the server answers tells no one: the answer may come after a
sign-out, and the lists open then may be the next user's.

## Screens

`GameBrowseScreen`, `GameSearchScreen` and `GameDetailScreen` each own their
bloc; the shell passes in the remote, the cache, the callbacks and, to
search, the session's access, and the screens resolve nothing themselves.

The detail screen renders the description as Markdown with
`flutter_markdown_plus` (#472): GitHub's extensions, raw HTML never rendered,
and only `http`, `https` and `mailto` links, opened outside the app through
`url_launcher`. The package was picked with a probe against the pinned
Flutter, which showed that it has no HTML rendering path and that every link
tap reaches one callback.

Run `melos run generate` once after checkout: the localizations under
`lib/l10n/` are generated and gitignored.
