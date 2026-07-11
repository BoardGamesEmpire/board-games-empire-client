/// Coarse-grained device connectivity, as consumed by the
/// [ServerOrchestrator] lifecycle and sync/auth flows (#9).
///
/// Deliberately binary-plus-reserve. Finer transport detail
/// (wifi/cellular/ethernet/vpn) is intentionally not modelled; if
/// metered-connection decisions arrive later, the enum extends without
/// breaking existing consumers.
///
/// Semantics follow the honest-`navigator.onLine` contract: [online]
/// means "connectivity exists, attempting will probably work"; [offline]
/// means "don't bother trying". Neither is a guarantee the BGE server is
/// reachable.
enum ConnectivityState {
  /// A network transport is available. Attempts are worth making.
  online,

  /// No network transport. Attempts are doomed; don't spend battery.
  offline,

  /// Connectivity cannot be determined.
  ///
  /// Reserved for forward-compat (a platform that genuinely cannot
  /// report state). The current `connectivity_plus` implementation
  /// never emits it: construction seeds [online] optimistically and an
  /// eager check corrects to the true state moments later (#9 design
  /// decision 4).
  unknown,
}
