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
