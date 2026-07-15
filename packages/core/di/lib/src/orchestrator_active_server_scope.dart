import 'dart:async';

import 'package:interfaces/orchestration.dart';

/// Native [ActiveServerScope] (#37): a thin, read-only adapter over the
/// [ServerOrchestrator].
///
/// Maps the orchestrator's active state into [ActiveServer] snapshots by
/// reading the active [ServerContext] — its container plus its `config`
/// (identity + display name). Because both come from the one live context
/// object, the pair is inherently consistent; there is no separate
/// `activeConfig` lookup to fall out of step.
///
/// ## Emission semantics
///
/// [watchActive] replays the current value on subscribe (the seam's
/// contract; the orchestrator's own stream has no replay) via the same
/// `Stream.multi` pattern as `AuthRepositoryImpl.watchAuthState`. Each
/// subsequent orchestrator emission triggers a re-read of the *current*
/// truth rather than mapping the (possibly stale, async-delivered) event
/// payload: after rapid successive commits this can deliver the same
/// [ActiveServer] twice, but never a stale or torn one. Emissions are
/// therefore not distinct — consumers keying on
/// [ActiveServer.serverId] treat repeats as no-ops (the value's equality
/// supports `distinct()` where wanted).
///
/// Owns no resources: subscriptions are per-listener and cancelled with
/// the listener; nothing to dispose.
class OrchestratorActiveServerScope implements ActiveServerScope {
  OrchestratorActiveServerScope({required ServerOrchestrator orchestrator})
    : _orchestrator = orchestrator;

  final ServerOrchestrator _orchestrator;

  @override
  ActiveServer? get active {
    final context = _orchestrator.getActiveContext();
    if (context == null) return null;
    final config = context.config;
    return ActiveServer(
      serverId: config.id,
      displayName: config.displayName,
      identity: config.cachedIdentity,
      container: context.container,
    );
  }

  @override
  Stream<ActiveServer?> watchActive() {
    return Stream.multi((controller) {
      controller.add(active);
      final sub = _orchestrator.watchActiveContext().listen(
        // Re-read current truth at delivery time instead of mapping the
        // event payload — see class docs, "Emission semantics".
        (_) => controller.add(active),
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = sub.cancel;
    });
  }
}
