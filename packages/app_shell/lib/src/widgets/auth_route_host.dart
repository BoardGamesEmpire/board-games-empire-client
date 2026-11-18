import 'dart:async';

import 'package:auth/auth.dart';
import 'package:flutter/material.dart';
import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart';

/// The `/auth` page: an [AuthGate] for the server active now, rebuilt
/// whenever another one becomes active (#134).
///
/// go_router keys a page by its route pattern, so a page built for one
/// server is kept when another becomes active with no navigation after it:
/// a switch from the server manager that lands once the user has gone Back
/// to the sign-in screen. Built from the server active when the page was
/// built, it would go on naming that server, and offering its ways in, over
/// the new server's session.
///
/// The sign-in screen starts afresh for the new server without a key of its
/// own: the new server's bloc starts unresolved, so the gate shows its
/// splash before the screen comes back, and the screen reads the count of
/// unsent changes it is handed here, the new server's.
class AuthRouteHost extends StatefulWidget {
  const AuthRouteHost({
    required this.scope,
    required this.splash,
    required this.unsentChangesCountOf,
    super.key,
    this.onManageServers,
  });

  /// Says which server is active, and when that changes.
  final ActiveServerScope scope;

  /// Passed to [AuthGate.splash]; shown on its own while no server is
  /// active.
  final Widget splash;

  /// The [AuthGate.unsentChangesCount] for a server.
  final Future<int> Function()? Function(ActiveServer active)
  unsentChangesCountOf;

  /// Passed to [AuthGate.onManageServers].
  final VoidCallback? onManageServers;

  @override
  State<AuthRouteHost> createState() => _AuthRouteHostState();
}

class _AuthRouteHostState extends State<AuthRouteHost> {
  static final BgeLogger _log = BgeLogger('bge.shell.auth_route_host');

  /// The server the gate is built for. Seeded from the scope, so the first
  /// frame is the gate rather than an empty one.
  ActiveServer? _active;

  StreamSubscription<ActiveServer?>? _subscription;

  @override
  void initState() {
    super.initState();
    _watch();
  }

  @override
  void didUpdateWidget(AuthRouteHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope != widget.scope) _watch();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  void _watch() {
    unawaited(_subscription?.cancel());
    _active = widget.scope.active;
    // The scope replays the server active now on subscribe, and may repeat
    // it. Only a change rebuilds: each build looks up the server's count of
    // unsent changes, and a lookup that fails logs.
    _subscription = widget.scope.watchActive().listen(
      (active) {
        if (active != _active) setState(() => _active = active);
      },
      // The gate stays on the server it has, as the shell's auth scope
      // does. Logged, so a sign-in screen left naming a server that is no
      // longer the active one can be explained.
      onError: (Object error, StackTrace stackTrace) => _log.warn(
        'The active-server stream failed; the sign-in page keeps the '
        'server it has',
        error: error,
        stackTrace: stackTrace,
        context: {'serverId': _active?.serverId},
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    // The active server went and none has replaced it yet. The shell mounts
    // no AuthBloc for the gate to read until one does.
    if (active == null) return widget.splash;
    return AuthGate(
      identity: active.identity,
      serverDisplayName: active.displayName,
      splash: widget.splash,
      unsentChangesCount: widget.unsentChangesCountOf(active),
      onManageServers: widget.onManageServers,
    );
  }
}
