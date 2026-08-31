/// One hydrate pass, on demand, for the screens that show what it produced
/// (#300 D5).
///
/// The household drain has had exactly one call site since #267 — user
/// session activation — and #302 added a second, the `SessionRehydrator`
/// the shell drives on a connectivity edge or an app resume. This is the
/// third, and the only one a person can press.
///
/// ## Why it is not the `SessionRehydrator`
///
/// The seam is right for a trigger and wrong for a button. A pass it
/// starts runs *every* stale feature, and it skips an entry that is
/// already running (#302 D4) — correct when a flapping connection is
/// firing it, and not correct when someone pressed a control and is
/// waiting to see what happens. A button that silently does nothing is the
/// one outcome a manual affordance cannot afford.
///
/// ## Why it is a class and not a bare function
///
/// It is resolved from a container by type, and a raw
/// `Future<void> Function()` is a type every other feature's callback
/// would share. A named class is the key.
///
/// ## What it does not need
///
/// A guard of its own. [HouseholdHydrator.hydrate] single-flights (#302
/// D3), so a press landing on top of the unawaited install-time pass joins
/// it rather than starting a second drain — the question #300 asked to
/// have answered rather than assumed.
///
/// Absent from a container that runs no drain at all (web until #125),
/// which the screens read as "no retry to offer" rather than offering a
/// button that does nothing.
class HouseholdRefresher {
  /// Wraps [pass] — the same closure the installer hands the
  /// `SessionRehydrator`, so a pressed refresh and a triggered one cannot
  /// report differently.
  const HouseholdRefresher(this._pass);

  final Future<void> Function() _pass;

  /// Runs one pass, driving the shared `HouseholdHydrationStatus` around
  /// it. Never throws: the pass reports failure through that status.
  Future<void> refresh() => _pass();
}
