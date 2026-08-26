/// Re-runs the hydrates of the **active user session** when something
/// suggests the server is worth asking again (#302).
///
/// Every cache that fills at user-session activation has the same problem:
/// its hydrate has exactly one call site, so a session that started while
/// the server was unreachable never asks again for the life of that
/// session. #267's household hydrate is simply the first one built, and
/// the household list is where it became visible (#269). The policy
/// belongs above the feature packages, which is why the seam is here and
/// not in `packages/features/household`.
///
/// ## Registration, not a switch statement
///
/// GetIt has no multibinding, so registration is explicit and mutable —
/// the same shape `UserDataExportRegistry` uses (#11). A hydrating
/// installer resolves this and registers itself; nothing in platform code
/// enumerates feature names. The composition root cannot discover
/// hydrates on its own: [DependencyContainer] exposes `get`/`isRegistered`
/// and no listing API.
///
/// ## Scoped to the session, deliberately
///
/// The concrete registry is registered in the **user-session scope**, so
/// its lifetime is the session's. That is what gives #302's "no re-run
/// when there is no active user session" rule for free: the scope teardown
/// disposes this, and a trigger that arrives afterwards has nothing to
/// call. It also matches how `HouseholdHydrationStatus` is registered and
/// disposed, keeping one lifetime story rather than two.
///
/// ## What a trigger looks like
///
/// The triggers themselves live in the app shell, not here and not in the
/// session scope: each `ServerContext` wraps its own GetIt instance and
/// resolution never falls through to the root container, so the
/// root-owned `ConnectivityService` is not resolvable where per-user
/// services live. The shell holds both halves and reaches this through the
/// active server's container.
///
/// One thing a trigger cannot do is prove the server is reachable. A
/// connectivity edge reports device transport (#9) — a server that is down
/// while the device stays online produces no edge at all, which is exactly
/// the run #302 was filed from. #300 (manual retry) and #311 (bounded
/// retry) cover that case; this seam carries all of them.
abstract interface class SessionRehydrator {
  /// Registers a re-runnable hydrate under [key].
  ///
  /// [isStale] is consulted at the start of every pass rather than
  /// remembered, so the entry's own status holder stays the single source
  /// of truth for whether the cache needs filling. A check that throws is
  /// treated as *not* stale — the alternative is a broken predicate
  /// re-running a drain on every trigger.
  ///
  /// [run] must not be assumed to throw or not throw: a pass isolates each
  /// entry, so one failure neither fails the pass nor skips the entries
  /// after it.
  ///
  /// Throws [ArgumentError] if [key] is already registered. A duplicate is
  /// a composition bug rather than a runtime condition — it is
  /// deterministic, identical on every launch, and silently clobbering one
  /// feature's hydrate with another's would be invisible in exactly the
  /// offline case this exists for.
  ///
  /// Dropped without throwing once the session scope has disposed this;
  /// see the class doc on lifetime.
  void register(
    String key, {
    required bool Function() isStale,
    required Future<void> Function() run,
  });

  /// Re-runs every registered hydrate that reports itself stale.
  ///
  /// Never throws, whatever the entries do. A pass triggered while one is
  /// in flight **joins** it rather than starting a second (#302 D3): a
  /// flapping connection would otherwise fan out into overlapping drains,
  /// and the install-time pass a trigger races is itself unawaited.
  Future<void> rehydrateStale();
}
