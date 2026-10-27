## 0.0.1

* Initial release (#496): `EventHydrator` caches every page of the events the
  signed-in user attends from `GET /events`, and removes the attendance the
  server no longer lists: all of it when the list fits on one page, and
  within page 1's range when it runs longer. Read-only: no screens, no writes.
* `EventHydrateInstaller` runs the hydrate whenever a user session activates,
  on native and web, and re-runs it through `SessionRehydrator` when the last
  pass failed or a completed one is five minutes old. A pass first checks that
  the session is still the scope's user, and the hydrator checks again before
  writing each page.
* `EventHydrationStatus` publishes what the pass is doing, and
  `EventRefresher` runs one on demand, for the event screens. A pass that
  ends `windowed` or `drained` reads as refreshed, like `complete`.
* The events overview (#497): `EventOverviewScreen` groups the cached events
  as Upcoming, Planning and Past by their confirmed dates, five to a group,
  and `EventGroupScreen` lists a whole group. Rows show the date in local time
  with the platform's 24-hour setting, the venue, the household and the
  user's RSVP where known. Its `onOpen` and `onCreate` hooks are optional:
  without them a row opens nothing, and there is no New event button.
* Creating an event (#499): `CreateEventScreen`, a form for an event's
  basics, dates, invitees and rules, checked before anything is written.
  `CreateEventBloc` writes the event on this device, queuing its create, then
  sends it once straight away through `SyncOperationSender`. A refusal stays
  on the form, under a banner that names the invitee or the household where
  it can. `eventCreateHouseholds` keeps, for the form's household picker, the
  households where the user's role may create one. The overview and group
  pages offer New event through `onCreate`, and the empty overview offers it
  under its message.
