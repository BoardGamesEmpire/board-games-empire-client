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
  ///
  /// [afterChange] backs [refreshAfterChange]; without it, that is
  /// [refresh].
  const GameCollectionRefresher(this._pass, {this._afterChange});

  final Future<void> Function() _pass;
  final Future<void> Function()? _afterChange;

  /// Runs one pass, driving the shared `GameCollectionHydrationStatus`
  /// around it. Never throws: the pass reports failure through that status.
  Future<void> refresh() => _pass();

  /// Runs a pass that starts after this call, waiting out one in flight.
  /// Never throws.
  ///
  /// For a local write the user is waiting to see corrected, such as a
  /// discarded sync op (#190). [refresh] joins a running pass, which may
  /// have merged that row's page before the write, and its catch-up asks
  /// only for rows the server changed since.
  Future<void> refreshAfterChange() => (_afterChange ?? _pass)();
}
