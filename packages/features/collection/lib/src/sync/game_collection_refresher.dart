/// One collection hydrate pass, on demand, for the list's retry (#44).
///
/// Not the `SessionRehydrator`, for the household's reason (#300): that
/// seam skips an entry whose pass is already running, which is right for a
/// trigger and wrong for a button someone is waiting on.
///
/// A named class rather than a bare `Future<void> Function()`, because it is
/// resolved from a container by type, and every feature's callback would
/// share that type.
///
/// It needs no guard of its own: `GameCollectionHydrator.hydrate`
/// single-flights, so a press landing on a running pass joins it.
class GameCollectionRefresher {
  /// Wraps [pass], the same closure the installer registers with the
  /// `SessionRehydrator`, so a pressed refresh and a triggered one report
  /// the same way.
  const GameCollectionRefresher(this._pass);

  final Future<void> Function() _pass;

  /// Runs one pass, driving the shared `GameCollectionHydrationStatus`
  /// around it. Never throws: the pass reports failure through that status.
  Future<void> refresh() => _pass();
}
