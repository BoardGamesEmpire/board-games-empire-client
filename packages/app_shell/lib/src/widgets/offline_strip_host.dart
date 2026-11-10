import 'dart:async';

import 'package:app_shell/l10n/shell_localizations.dart';
import 'package:flutter/widgets.dart';
import 'package:interfaces/services.dart';
import 'package:observability/observability.dart';
import 'package:ui/ui.dart'
    show BgeConnectivityScope, BgeOfflineStrip, BgeOfflineStripState;

/// Turns [ConnectivityService.watch] into the window's offline strip and the
/// debounced flag its controls read (#49).
///
/// Draws a [BgeOfflineStrip] above [child] and publishes a
/// [BgeConnectivityScope] over both. `BgeApp` mounts it in the
/// `MaterialApp.router` builder, above the Navigator, so it reaches every
/// route.
///
/// ## Timing
///
/// The strip shows once the connection has been lost for [showAfter], and
/// the scope's `offline` turns true with it, so a connection that drops and
/// returns inside that wait changes nothing on screen. When the connection
/// returns, `offline` turns false at once, so controls come back at
/// reconnect, while the strip says "Back online" for [backOnlineHold] and
/// then collapses. A loss during that hold puts the offline text back on
/// the same strip, without collapsing it. [ConnectivityState.unknown] counts
/// as online: only a reported loss shows the strip.
///
/// `watch()` replays the current state to every new subscriber, so an app
/// launched offline starts the wait like any other loss. A repeated state
/// is no event: neither a duplicate nor the replay after resubscribing
/// restarts the wait or the hold. A new service instance replaces the old
/// one's subscription. No service at all means online, with nothing drawn.
/// An error on the stream is logged and changes nothing: a connectivity
/// hiccup must not reach the uncaught-error hooks, which would put the
/// crash prompt over it.
///
/// ## Layout
///
/// While the strip shows, its hold included, it takes the window's top inset
/// itself, so the content below has that inset removed; otherwise every app
/// bar would inset the status bar a second time. The strip switches its own
/// inset in the same frame, so the content does not jump at either edge.
///
/// The tree has one shape in every state, with or without a service: only
/// `removeTop` switches. Swapping a [MediaQuery] for the bare child, or
/// leaving the strip out until a service exists, would remount everything
/// between here and the Navigator, the router included, whenever the strip
/// came or went or the service arrived.
///
/// The content sits in its own semantics container. Every route carries a
/// modal barrier whose [BlockSemantics] drops the semantics of whatever was
/// painted before it, up to the nearest container. Without one here the
/// strip, painted first, would never reach a screen reader.
class OfflineStripHost extends StatefulWidget {
  const OfflineStripHost({
    required this.connectivity,
    required this.child,
    this.showAfter = const Duration(seconds: 2),
    this.backOnlineHold = const Duration(seconds: 2),
    super.key,
  });

  /// The root container's service. Null on a composition without one, or
  /// before it is registered: online, with nothing drawn.
  final ConnectivityService? connectivity;

  /// How long the connection must stay lost before the strip shows.
  final Duration showAfter;

  /// How long "Back online" stays before the strip collapses.
  final Duration backOnlineHold;

  /// The app below the strip.
  final Widget child;

  @override
  State<OfflineStripHost> createState() => _OfflineStripHostState();
}

/// Where the host is in an offline episode.
enum _Phase {
  /// Online, nothing drawn.
  hidden,

  /// Offline for less than [OfflineStripHost.showAfter]: nothing drawn yet,
  /// and controls stay enabled.
  waiting,

  /// The strip says the connection is lost, and controls are disabled.
  showingOffline,

  /// The strip says "Back online" for [OfflineStripHost.backOnlineHold].
  /// Controls are enabled again.
  holding,
}

class _OfflineStripHostState extends State<OfflineStripHost> {
  static final BgeLogger _log = BgeLogger('bge.shell.offline_strip');

  StreamSubscription<ConnectivityState>? _subscription;

  /// The wait while [_Phase.waiting], the hold while [_Phase.holding].
  Timer? _timer;

  _Phase _phase = _Phase.hidden;

  @override
  void initState() {
    super.initState();
    _subscription = _listen();
  }

  @override
  void didUpdateWidget(OfflineStripHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(widget.connectivity, oldWidget.connectivity)) return;
    unawaited(_subscription?.cancel());
    if (widget.connectivity == null) {
      // A service going away says nothing about the connection, so the
      // strip goes without claiming it is back.
      _timer?.cancel();
      _phase = _Phase.hidden;
    }
    // The new service's replay moves the episode on from where it is.
    _subscription = _listen();
  }

  /// Listens to the service, if there is one. An error keeps the episode
  /// where it is; see the class docs.
  StreamSubscription<ConnectivityState>? _listen() =>
      widget.connectivity?.watch().listen(
        _onState,
        onError: (Object error, StackTrace stackTrace) => _log.warn(
          'Connectivity stream failed',
          error: error,
          stackTrace: stackTrace,
        ),
      );

  void _onState(ConnectivityState state) {
    final offline = state == ConnectivityState.offline;
    switch (_phase) {
      case _Phase.hidden when offline:
        // No rebuild into or out of the wait: it looks exactly like hidden.
        _phase = _Phase.waiting;
        _timer = Timer(widget.showAfter, () => _enter(_Phase.showingOffline));
      case _Phase.waiting when !offline:
        _timer?.cancel();
        _phase = _Phase.hidden;
      case _Phase.showingOffline when !offline:
        _enter(_Phase.holding);
        _timer = Timer(widget.backOnlineHold, () => _enter(_Phase.hidden));
      case _Phase.holding when offline:
        _timer?.cancel();
        _enter(_Phase.showingOffline);
      case _:
        // The state this phase already stands for: a duplicate, or the
        // replay after resubscribing. It restarts neither timer.
        break;
    }
  }

  void _enter(_Phase phase) => setState(() => _phase = phase);

  @override
  void dispose() {
    _timer?.cancel();
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = ShellLocalizations.of(context);
    final strip = switch (_phase) {
      _Phase.hidden || _Phase.waiting => BgeOfflineStripState.hidden,
      _Phase.showingOffline => BgeOfflineStripState.offline,
      _Phase.holding => BgeOfflineStripState.backOnline,
    };
    // True exactly while the strip pads the top inset itself.
    final noticeShowing = strip != BgeOfflineStripState.hidden;
    return BgeConnectivityScope(
      offline: _phase == _Phase.showingOffline,
      noticeShowing: noticeShowing,
      onlineOnlyReason: l10n.shellOnlineOnlyReason,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BgeOfflineStrip(
            state: strip,
            offlineMessage: l10n.shellOfflineMessage,
            backOnlineMessage: l10n.shellBackOnlineMessage,
          ),
          Expanded(
            child: Semantics(
              container: true,
              explicitChildNodes: true,
              child: MediaQuery.removePadding(
                context: context,
                removeTop: noticeShowing,
                child: widget.child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
