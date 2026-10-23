# events

The events feature (#496). For now it holds the hydrate: the pass that keeps
a per-user cache of the events the signed-in user attends, which every event
screen will read.

## The hydrate

`EventHydrator` pages through `GET /events`, the events the user holds an
attendee row for, hosts and unanswered invitations included, and caches each
one through `EventRepository.cacheEvent` as `attending` access. A list row
carries the event's occurrences and its policy but no roster. Only the detail
read, `GET /events/:id`, carries one.

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

- **On a list that fits on page 1**, a page numbered as another page, or whose
  counts disagree with its rows or with being the only page, fails the pass
  (`failed`). One that sends fewer events than it counts ends `drained`.
- **On a longer list**, a page 1 that says another page follows past its own
  last page fails the pass (`failed`). One that is short of its limit,
  numbered as another page, empty, or counted in a way that disagrees with it
  leaves the pass `drained` at best, since a later page can still fail it.

A pass considers only the events that were purgeable before it requested
page 1, and never one with local changes. The user's `read` access stays, and
so does every other user's. An event that no one can read any more is
deleted from the cache.

The accepted cost: an event created before page 1's range that the user
leaves stays on their list until the list fits on one page, or until a detail
read answers 404 for it. Acting on that 404 comes with the screens, #497 and
#498.

## Shape

- `EventHydrator`: one pass, single-flight.
- `EventHydrateOutcome`: what a pass achieved, `complete`, `windowed`,
  `drained` or `failed`.

The remote is `EventRemoteDataSource` in `network_interface`, implemented in
`dio_network` and registered per server on both platforms. The cache is
`EventRepository` in `interfaces`, implemented in `drift_storage` and
registered in the user-session scope.

## Not here yet

- **Screens.** The event list is #497 and the event detail #498.
- **Writes.** Creating an event is #499, and answering an invitation or voting
  is #527. Nothing here queues or sends anything.
