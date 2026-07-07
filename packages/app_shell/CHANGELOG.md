## 0.0.1

Initial internal release (#31).

* `runBgeApp` entry point with observability, error-hook, and `runApp` wiring.
* `AppBootstrapCubit` / `AppBootstrapState` bootstrap state machine with
  retry and confirmed-destructive-reset policy.
* `PlatformBootstrap` contract and `BootstrapResult`.
* go_router configuration driven by bootstrap state, including the reserved
  deep-link path subtree.
* Shell screens: splash, bootstrap-error, not-yet-available, and
  server-add/auth/home placeholders.
* `ShellObservability` process-wide breadcrumb capture.
