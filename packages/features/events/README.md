# events

The events feature: the hydrate (#496), the overview (#497), the detail
(#498) and creating an event (#499). The hydrate is the pass that keeps a
per-user cache of the events the signed-in user attends, which every event
screen reads, and what the screens can learn from it and ask of it. The
overview is the first screen to read it, the detail shows one event from it,
and the create form writes a new one to it and sends it to the server.

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
leaves stays on their list until the list fits on one page, or until they
open it and its detail read answers 404, which forgets it (see the detail,
below).

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

## The overview

`EventOverviewScreen` shows the user's events as Upcoming, Planning and Past,
five to a group, from `EventRepository.watchAttendingEventListItems`: each
event with its dates and the user's own attendee row. `groupEvents` places
each event by its confirmed dates, not its status, against the clock at every
emission, so an event that ends while the overview is open moves to Past at
the next one. A group holding more than five has a *See all* button that opens
`EventGroupScreen`, which lists the whole group lazily over the cache. Each
row shows its title, its date in device-local time with the platform's
24-hour setting, its venue, its household's name from the cached households,
and the user's RSVP where their row is cached, which until backend#867 is
only after a detail read. The screens take hooks a composition may leave
out: without `onOpen` a row is inert, and without `onCreate` there is no New
event button, neither the one beside the list nor the one the empty overview
offers under its message. The shell wires `onOpen` to the detail and
`onCreate` to the create form. It opens the overview from the home drawer at
`/events`, and each group at `/events/upcoming`, `/events/planning` and
`/events/past`.

## The detail

`EventDetailScreen` shows one event, at `/events/:eventId` above the list it
was opened from, from `EventRepository.watchEvent`: the cached snapshot with
the user's own row on its roster. `EventDetailBloc` drives it, and its class
doc has the full state table. Every open reads `GET /events/:id` once and
writes the answer back as `read` access, so the screen shows the cache at
once and the server's answer when the watch delivers it. A failed read keeps
the cached event up under a banner with a retry. A local-only event is never
read, since the server has never heard of its id.

A 404 means the server no longer serves the user the event, and
`EventRepository.forgetEvent` removes their access, so it leaves the overview
at once. The forget is handed `EventRepository.lastWrite`, read before the
request went out, and leaves an event written since: a later open or a
hydrate may have cached it again while the 404 was out, and that newer write
wins, on screen as in the cache.

Before the request goes out, and again before its answer is written or its
404 acted on, the bloc asks the server's `SessionIdentityGuard` whether the
session is still this scope's user, as the hydrate does. A refusal is a
failed read. Native has no guard and is always confirmed.

`eventActionsFor` maps the viewer's event role, and their household role on a
household event, to what they may do to it. The screen shows no buttons yet:
each action's issue (#500 to #518) adds its own and reads that table.

## Creating an event

`CreateEventScreen` is the form for a new event (#499): its basics, *When*
(one date, several days or a poll, and its dates), *Who's invited*, found
through the shared `user_search` package, and *Advanced: rules*, then the
submit. The form checks what it can before anything is written: a title, a
start for each date shown, two dates or more for a poll or several days,
each end at or after its start, a link the server's `@IsUrl()` takes, and
each rule's number in its range. What the user leaves untouched is not sent,
so the server's defaults apply. The household picker offers the cached
households the user may create an event in, as `eventCreateHouseholds`
filters them by role. It starts in the household a link names once a list
offers it, unless the user has picked a household or submitted first.

`CreateEventBloc` writes the event on this device first, through
`EventRepository.create`, which queues its create in the same transaction.
It then sends that queued create once, straight away, through the session's
`SyncOperationSender`, the delivery path the queue drain takes too. A create
the server took, or one that stays queued for the drain to send, takes the
user to the event. On web no drain runs yet (#447), so a create whose first
send fails stays queued there. One the server refuses keeps the user on the
form under a banner, which names the invitee or the household when it can. A
403 for a create in a household also reads the user's households again, since
their role there may have changed elsewhere. The refused create stays parked:
the next submit discards it and creates afresh, unless another tab has
retried it since, whose event then stands and is the one the user is taken
to. One the user leaves behind waits on the sync queue's own surface (#190).

The shell routes the form at `/events/create`, where `?household=` names the
household to start in, and offers every way in to it: New event beside the
overview and each group's list, and on the empty overview, and the New event
row on a household's page, which starts in that household. It offers them
only where the session holds what the form needs, the event repository, the
sync sender and the person search, and the route falls back without them. A
created event's detail takes the form's place, so back never lands on it.

Run `melos run generate` once after checkout: the localizations under
`lib/l10n/` are generated and gitignored.

## Not here yet

- **Other writes.** Editing an event is #500, and answering an invitation or
  voting is #527. Fixing a refused create from the sync queue's surface is
  #590.
- **Invitations.** Whether invited events get a group of their own is #568.
