## 0.0.1

Initial internal release (#9).

* `ConnectivityService` shared implementation `ConnectivityPlusService`,
  wrapping the federated `connectivity_plus` plugin so one package serves
  both the native and web composition roots without dependency bleed.
* Optimistic `online` seed corrected by an eager `checkConnectivity()`;
  coarse `online`/`offline` mapping (`[none]`-only or empty → offline).
* Replay-on-subscribe via a seeded `BehaviorSubject`, with consecutive
  duplicate coarse states suppressed.
* `Disposable` conformance so the root container drives subscription and
  subject teardown; registered lazily by both root modules.
