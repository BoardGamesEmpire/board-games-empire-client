/// An exclusive lock shared by every tab of the origin (#447).
///
/// The sync queue drain runs each pass under one, so that a user's browser
/// tabs, which share one database, don't each send the same queued ops. Web
/// registers an implementation over the browser's Web Locks; native has one
/// process and registers none.
abstract interface class CrossTabLock {
  /// Waits for the exclusive lock [name], runs [body] holding it, then
  /// releases it, also when [body] throws, whose error propagates.
  ///
  /// Returns false without running [body] when [abandon] completes before
  /// the lock is granted; true once [body] has run. An implementation may
  /// listen to [abandon] for as long as it is pending, so a caller passes
  /// one per run rather than one that outlives many.
  Future<bool> run(
    String name,
    Future<void> Function() body, {
    Future<void>? abandon,
  });
}
