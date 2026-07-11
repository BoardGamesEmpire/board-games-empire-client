import 'connectivity_state.dart';

/// Device connectivity awareness (#9, Tier 1).
///
/// Consumers ([ServerOrchestrator] transitions, sync-queue drain
/// gating, auth-flow fast-fail — all later issues) depend only on this
/// read/watch surface. Per ISP, lifecycle (`dispose`) is deliberately
/// **not** part of this interface: it lives on the concrete
/// implementation and is owned by the composition root that constructs
/// it.
///
/// The concrete implementation lives in
/// `packages/platform/connectivity_platform` (shared across native and
/// web — `connectivity_plus` is federated, so the twin-package split
/// used for `BuildInfoReader` is unnecessary here).
abstract interface class ConnectivityService {
  /// Current connectivity state.
  ///
  /// Seeded optimistically to [ConnectivityState.online] at
  /// construction; an eager platform check corrects it to the true
  /// state shortly after. Always reflects the latest known state
  /// thereafter.
  ConnectivityState get current;

  /// Stream of state changes.
  ///
  /// Replays [current] to every new subscriber, then emits on each
  /// coarse-state change. Consecutive duplicates (e.g. wifi → ethernet,
  /// both [ConnectivityState.online]) are not re-emitted.
  Stream<ConnectivityState> watch();
}
