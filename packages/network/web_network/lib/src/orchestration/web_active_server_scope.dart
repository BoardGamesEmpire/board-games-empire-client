import 'dart:async';

import 'package:interfaces/orchestration.dart';

/// Web [ActiveServerScope] (#96): a constant, single-value holder.
///
/// Web has no orchestrator and no server switching in alpha — the browser
/// talks to exactly one origin, whose identity is fetched at bootstrap
/// ([bootstrapWebServerScope]). This scope therefore holds a single
/// [ActiveServer] fixed at construction: [active] is always non-null, and
/// [watchActive] replays that one value to every subscriber and then stays
/// open without ever emitting again.
///
/// This is the intentional "not a degenerate orchestrator" shape the seam
/// docs describe. Sign-out is handled by the auth bloc resolved from the
/// server's [ActiveServer.container]; it never clears the active server, so
/// there is deliberately no path that emits `null`.
class WebActiveServerScope implements ActiveServerScope {
  /// Creates a scope that always reports [_active] as the active server.
  WebActiveServerScope(this._active);

  final ActiveServer _active;

  @override
  ActiveServer? get active => _active;

  @override
  Stream<ActiveServer?> watchActive() {
    return Stream.multi((controller) {
      // Replay the one value on subscribe (the seam's contract), then leave
      // the stream open: there is no upstream and never a second emission,
      // so the controller closes only when the listener cancels. Uses the
      // same Stream.multi replay pattern as OrchestratorActiveServerScope.
      controller.add(_active);
    });
  }
}
