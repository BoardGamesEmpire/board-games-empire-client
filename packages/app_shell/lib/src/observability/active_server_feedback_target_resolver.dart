import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:observability/observability.dart';

/// Production [FeedbackTargetResolver] (#97): adapts the shell's
/// [ActiveServerScope] into the [FeedbackTarget] snapshot the
/// device-global `FeedbackService` reads per `submit`/`drainPending`.
///
/// Resolution, evaluated fresh on every call:
///
/// - No scope yet (pre-bootstrap, failed boot) or no active server →
///   null. The service queues **untagged**; such device-global
///   diagnostics drain into whatever server is active later.
/// - Active server → a target carrying its stable `bgeServerId`
///   ([ActiveServer.identity]'s `serverId` — uniform across native and
///   web, unlike the platform-divergent [ActiveServer.serverId]).
/// - The transport is attached only when the active container holds an
///   [AuthRepository] whose [AuthRepository.currentAuthState] is
///   [AuthStateAuthenticated] **and** a registered [FeedbackTransport]
///   (the feedback endpoint requires a session). Otherwise the target
///   has a null transport and the service queues, correctly tagged.
///
/// [scopeSource] is a function, not a scope instance, on purpose: the
/// scope is owned by `AppBootstrapCubit` and is **replaced** on every
/// bootstrap retry, so anything holding a scope captured at composition
/// time would go stale. Reading through the cubit at resolve time keeps
/// this adapter registrable once, device-globally, for the app's whole
/// life. The container lookups are `isRegistered`-guarded because a
/// scope can legitimately exist before its network leg is installed.
class ActiveServerFeedbackTargetResolver implements FeedbackTargetResolver {
  const ActiveServerFeedbackTargetResolver({
    required ActiveServerScope? Function() scopeSource,
  }) : _scopeSource = scopeSource;

  final ActiveServerScope? Function() _scopeSource;

  @override
  FeedbackTarget? resolve() {
    final active = _scopeSource()?.active;
    if (active == null) return null;

    final container = active.container;
    FeedbackTransport? transport;
    if (container.isRegistered<AuthRepository>() &&
        container.get<AuthRepository>().currentAuthState
            is AuthStateAuthenticated &&
        container.isRegistered<FeedbackTransport>()) {
      transport = container.get<FeedbackTransport>();
    }

    return FeedbackTarget(
      serverId: active.identity.serverId,
      transport: transport,
    );
  }
}
