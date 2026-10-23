# events

The events feature (#496). For now it holds the hydrate: the pass that keeps
a per-user cache of the events the signed-in user attends, which every event
screen will read, and what the screens can learn from it and ask of it.

## The hydrate

`EventHydrator` pages through `GET /events`, the events the user holds an
attendee row for, hosts and unanswered invitations included, and caches each
page in one write through `EventRepository.cacheEvents`, as `attending`
access, so a screen watching the list rebuilds once a page rather than once
an event. A list row carries the event's occurrences and its policy but no
roster. Only the detail read, `GET /events/:id`, carries one.

It follows `hasMore` to the end, at the server's page-size cap. The list is
ordered by creation, not by date, so an old event with an upcoming date can
sit on any page, and every page is cached.

It never throws. A pass that ends on a failure, such as no connection, a
server without the events routes, or a session that ended or changed hands
mid-pass, reports `failed`. It keeps every page it wrote, and any purge page 1
already made: on a list longer than one page that purge runs before page 2 is
requested, so a later page that fails leaves it done. A call made while a pass
is running is handed that same pass.

## What a pass removes

Without a purge the cache only grows, so an event the user left, was removed
from, or that was deleted would stay on their list. A pass removes the user's
`attending` access where the server's answer proves the event is no longer
theirs, and nowhere else. Only page 1 can prove it. A walk across pages is not
one snapshot, but page 1 is: its rows and count come from one REPEATABLE READ
read, in a total order, newest created first.

- **The list fits on page 1** (`complete`). That page is the whole list, so
  every attending event it leaves out is removed.
- **The list runs past page 1** (`windowed`). An attending event created after
  page 1's last row that page 1 leaves out is removed. Older ones are kept,
  and so is one created at the same instant as that row, because the server
  orders a tie by id in a collation SQLite can't reproduce.

Page 1 proves nothing when its envelope contradicts itself, or when it may
have left out events it counts. Then nothing is removed, and:

- **On a list that fits on page 1**, a page numbered as another page,
  counting other than one page, or sending more events than it counts fails
  the pass (`failed`). One that sends fewer events than it counts ends
  `drained`.
- **On a longer list**, a page 1 that says another page follows past its own
  last page fails the pass (`failed`). One that is short of its limit,
  numbered as another page, empty, or counted in a way that disagrees with it
  leaves the pass `drained` at best, since a later page can still fail it.

A pass considers only the events that were purgeable before it requested
page 1 and haven't been written since, by another tab's pass say, and never
one with local changes. With the user's attendance goes
their own row on the event's cached roster. The user's `read` access stays,
and so does every other user's, roster rows included. An event that no one
can read any more is deleted from the cache.

The accepted cost: an event created before page 1's range that the user
leaves stays on their list until the list fits on one page, or until a detail
read answers 404 for it. Acting on that 404 comes with the screens, #497 and
#498.

## When it runs

`EventHydrateInstaller` starts a pass, unawaited, whenever a user session
activates, on native and web alike. Activation is the sign-in gate, so the
network stays off it: the screens render from the cache whatever the pass
does.

It also joins the session's `SessionRehydrator`, under the key `events`, so
a later trigger such as a connectivity edge or an app resume runs another pass
when the last one failed or none has completed, and when a completed one is
five minutes old (`EventHydrateInstaller.staleAfter`). A trigger that lands
while a pass is running is dropped. Each re-run is a full drain.

Where the server has no event client or the session has no event cache, it
registers nothing, and a screen reads that as no hydrate running here.

On web another tab can move the shared session cookie to another user. So
every pass asks `SessionIdentityGuard` whether the session is still this
scope's user before it sends anything, and the hydrator asks again after each
page, before writing it. A refused pass reads as `failed`, and the next
trigger tries again. Native has no guard and is always confirmed.

## What a screen reads, and what it may press

Both are registered in the user-session scope.

- **`EventHydrationStatus`** is what a screen reads. `watch()` replays the
  current `EventHydration` and then every change. It carries the `state`
  (`idle`, `running`, `refreshed` or `failed`), whether any pass has ever
  refreshed the cache, and whether the last one failed. The history is in the
  reading because a screen usually opens mid-pass and sees only the current
  one. An empty cache under `running` is still filling, and under `refreshed`
  it is empty. Under `failed` every page the pass wrote stays, and so does
  any purge its page 1 already made: the rows are safe to display, possibly
  stale. An absent status means no hydrate runs here, and reads as `idle`.
- **`EventRefresher`** is what a screen may press. `refresh()` runs one pass
  and drives the same status, so a retry clears the banner the screen already
  shows. A press is not a trigger: it runs whether or not the cache is stale,
  and joins a pass already running rather than starting a second. It never
  throws. An absent refresher means there is no retry to offer.

`complete`, `windowed` and `drained` all read as `refreshed`. Each cached
every page the server sent, which is what the screens show, and they differ
only in what the purge could remove. Reading `windowed` or `drained` as
`failed` would put a failure banner over current rows, and would send every
trigger back for a drain that cannot do better until the list changes.

## Shape

- `EventHydrator`: one pass, single-flight.
- `EventHydrateOutcome`: what a pass achieved, `complete`, `windowed`,
  `drained` or `failed`.
- `EventHydrationStatus`, with its `EventHydration` readings and
  `EventHydrationState`: what the pass is doing and what earlier ones
  established.
- `EventRefresher`: one pass on demand.
- `EventHydrateInstaller`: runs a pass on session activate, publishes the
  status and the refresher, and registers the pass for re-runs.

The remote is `EventRemoteDataSource` in `network_interface`, implemented in
`dio_network` and registered per server on both platforms. The cache is
`EventRepository` in `interfaces`, implemented in `drift_storage` and
registered in the user-session scope. The installer runs after the
user-session storage installer and the rehydrator's, in both composition
roots, `native_platform` and `web_platform`.

## Not here yet

- **Screens.** The event list is #497 and the event detail #498.
- **Writes.** Creating an event is #499, and answering an invitation or voting
  is #527. Nothing here queues or sends anything.
