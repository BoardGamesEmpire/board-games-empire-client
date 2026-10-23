## 0.0.1

* Initial release (#496): `EventHydrator` caches every page of the events the
  signed-in user attends from `GET /events`, and removes the attendance the
  server no longer lists: all of it when the list fits on one page, and
  within page 1's range when it runs longer. Read-only: no screens, no writes.
