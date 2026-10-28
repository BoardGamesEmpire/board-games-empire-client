/// One event hydrate pass, on demand, for the screens that show what it
/// produced (#496).
///
/// Not the `SessionRehydrator`, for the household's reason (#300): that seam
/// skips an entry whose pass is already running, which is right for a trigger
/// and wrong for a button someone is waiting on. A refresh that silently does
/// nothing is the one outcome a manual affordance cannot afford.
///
/// A named class rather than a bare `Future<void> Function()`, because it is
/// resolved from a container by type, and every feature's callback would
/// share that type.
///
/// It needs no guard of its own: `HydratePass` single-flights (#302), so a
/// press landing on a running pass joins it and waits for it. Nor does it take
/// a callback for after a local change, as the collection's does. A discarded
/// create (#499) is the one local change it follows, and a pass in flight
/// cannot have merged around it: a pass never writes over a local-only event,
/// and the server's copy of an event carries its own id.
///
/// Absent from a container that runs no event hydrate at all (see
/// `EventHydrateInstaller` for which those are), which the screens read as
/// "no retry to offer" rather than offering a button that does nothing.
class EventRefresher {
  /// Wraps [pass], the shared pass's `run`, which the installer also
  /// registers with the `SessionRehydrator`, so a pressed refresh and a
  /// triggered one report the same way.
  const EventRefresher(this._pass);

  final Future<void> Function() _pass;

  /// Runs one pass, driving the shared `EventHydrationStatus` around it.
  /// Never throws: the pass reports failure through that status.
  Future<void> refresh() => _pass();
}
