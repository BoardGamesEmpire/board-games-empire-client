import 'dart:async';

import 'package:app_shell/src/deep_links/deep_link_failure.dart';
import 'package:app_shell/src/deep_links/deep_link_normalizer.dart';
import 'package:app_shell/src/deep_links/known_server_lookup.dart';
import 'package:app_shell/src/deep_links/pending_deep_link_holder.dart';
import 'package:app_shell/src/router/app_router.dart';
import 'package:app_shell/src/servers/server_activation.dart';
import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart';

/// Drains the [PendingDeepLinkHolder]: decides where a held link goes —
/// straight to its location, to the unknown-server screen, or through a
/// server switch first (#82).
///
/// A link stays in the slot until it lands, and is taken only when it lands
/// or is dropped. Making the link's server active can drop the app to the
/// sign-in screen (the target has no session), and the link must survive
/// that to the next Ready, which drains again and lands it on the
/// now-active server (#82).
///
/// Every await in a pass is followed by a re-check, because the world can
/// move while it waits: a newer link may have replaced this one (its own
/// arrival has already queued another pass, so this one just stops), the
/// app may have left Ready, or the consumer may have been disposed. Only a
/// pass whose link is still the held one, in a ready app, navigates.
///
/// Passes coalesce: one asked for during a pass runs as one more pass after
/// it, never alongside it.
///
/// After a switch, the app is still Ready from the old server until the new
/// server's sign-in outcome arrives. Until then nothing lands on the new
/// server: a pass in that window, asked for by a link arriving or by the
/// switch's own pass, leaves the link held. The outcome is [drain]: the
/// shell's authenticated signal. A server that needs sign-in leaves Ready
/// instead, and its sign-in drains later (#82). Links for other servers are
/// acted on at once, so the newest link still wins.
///
/// A switch happens once per link delivery. If a later pass finds that
/// link's server no longer active, the app has moved elsewhere since the
/// switch, and the link is dropped rather than switched to again or left to
/// land by surprise when the user returns to that server (#82). Every
/// delivery is a new request, so a link sent again, even one equal to the
/// held link, is switched to again.
///
/// Web passes no lookup and no orchestrator (single-origin, the server
/// segment is carried but ignored), so a link there goes straight to its
/// location. The only link web holds is the location the page was loaded
/// at, which the router writes to the slot on its first redirect (#83).
class DeepLinkConsumer {
  DeepLinkConsumer({
    required this._holder,
    required this._isReady,
    required this._lookup,
    required this._orchestrator,
    required this._go,
    this._onFailure,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.shell.deep_links');

  final PendingDeepLinkHolder _holder;

  /// Whether the app is ready to route (the bootstrap cubit is in
  /// `AppBootstrapReady`).
  final bool Function() _isReady;

  /// Late-bound: the lookup exists only once bootstrap has composed it.
  final KnownServerLookup? Function() _lookup;

  /// Late-bound, like [_lookup].
  final ServerOrchestrator? Function() _orchestrator;

  final void Function(String location) _go;

  /// Told when a link is given up on because its lookup or switch failed,
  /// so the shell can say so (#984). Not called for the deliberate drop or
  /// for a server not added here.
  final void Function(DeepLinkFailure failure)? _onFailure;
  final BgeLogger _logger;

  bool _disposed = false;
  bool _draining = false;
  bool _again = false;

  /// The link whose server this consumer last made active, while that
  /// delivery of it is still held. Met again while that server isn't
  /// active, the link is dropped: the switch happened, and the app has moved
  /// off it since. A link arriving clears it.
  NormalizedDeepLink? _switchRequestedFor;

  /// The local id of the server this consumer last made active, until that
  /// server's sign-in outcome arrives ([drain]). While it is the active
  /// server, nothing lands.
  String? _awaitingSignInOn;

  /// Listens to the holder and drains once, for a link held before start.
  void start() {
    _holder.addListener(_onLinkArrived);
    unawaited(_requestPass());
  }

  /// Drains the slot on the shell's authenticated signal: the active server
  /// has a session. That is also how the app enters Ready, so it covers a
  /// link held through bootstrap and sign-in, and it is the sign-in outcome
  /// a server switch waits for. Links that arrive drain on their own.
  ///
  /// A call during a pass coalesces into one more pass after it, and
  /// returns at once, before that pass has run, so awaiting [drain] does
  /// not mean the held link has landed.
  Future<void> drain() {
    _awaitingSignInOn = null;
    return _requestPass();
  }

  Future<void> _requestPass() async {
    if (_disposed) return;
    if (_draining) {
      _again = true;
      return;
    }
    _draining = true;
    try {
      do {
        _again = false;
        await _pass();
      } while (_again && !_disposed);
    } finally {
      _draining = false;
    }
  }

  /// Stops listening; a drain in flight navigates nowhere after this. The
  /// holder is not the consumer's to dispose.
  void dispose() {
    _disposed = true;
    _holder.removeListener(_onLinkArrived);
  }

  /// A delivery is a new request, even of a link equal to the held one, so
  /// it forgets the switch made for an earlier delivery.
  void _onLinkArrived() {
    _switchRequestedFor = null;
    unawaited(_requestPass());
  }

  /// Whether a pass for [link] may still act after an await.
  bool _stillCurrent(NormalizedDeepLink link) =>
      !_disposed && _isReady() && _holder.peek == link;

  Future<void> _pass() async {
    final link = _holder.peek;
    // A pending switch belongs to the link it was made for, while that link
    // is held. Once another replaces it or the slot empties, the same link
    // sent again is a new request, not one the app has moved off.
    if (_switchRequestedFor != link) _switchRequestedFor = null;
    if (_disposed || !_isReady() || link == null) return;

    final lookup = _lookup();
    final orchestrator = _orchestrator();
    if (lookup == null || orchestrator == null) {
      _land(link, link.location);
      return;
    }

    final String? localId;
    try {
      localId = await lookup.localServerIdFor(link.serverId);
    } on Object catch (error, stackTrace) {
      _drop(
        link,
        'looking up its server',
        const DeepLinkLookupFailed(),
        error,
        stackTrace,
      );
      return;
    }
    if (!_stillCurrent(link)) return;

    if (localId == null) {
      _holder.takeIf(link);
      _logger.info('Deep link names a server not added here: $link');
      _go(AppRoutes.deepLinkUnknownServer);
      return;
    }

    if (localId == orchestrator.activeServerId) {
      // Switched to, and its sign-in outcome isn't known yet: landing now
      // would take the link from a sign-in that may still need it.
      if (_awaitingSignInOn == localId) return;
      _switchRequestedFor = null;
      _land(link, link.location);
      return;
    }

    // This link's server was already made active, and isn't any more: the
    // orchestrator commits a switch before its Future completes, so the
    // user or the app has moved elsewhere since. Landing it later, when the
    // user happens back onto that server, would be a surprise (#82).
    if (_switchRequestedFor == link) {
      _switchRequestedFor = null;
      _holder.takeIf(link);
      _logger.info(
        'Deep link dropped: its server is no longer active after the '
        'switch to it: $link',
      );
      return;
    }

    _switchRequestedFor = link;
    try {
      await activateServer(orchestrator, localId);
    } on Object catch (error, stackTrace) {
      _drop(
        link,
        'making its server active',
        DeepLinkActivationFailed(error),
        error,
        stackTrace,
      );
      return;
    }
    // The app is still Ready from the old server, and the new server's
    // sign-in outcome drains when it arrives (#82). Set after the switch,
    // so an authenticated signal from the old server during it can't clear
    // the wait. The new server's own signal can't arrive inside the switch:
    // the orchestrator commits the new active server and completes with no
    // I/O in between, and that signal needs a later frame (the auth scope
    // rebuild) and a session check.
    _awaitingSignInOn = localId;
  }

  void _land(NormalizedDeepLink link, String location) {
    _holder.takeIf(link);
    _logger.info('Deep link landed: $link');
    _go(location);
  }

  void _drop(
    NormalizedDeepLink link,
    String step,
    DeepLinkFailure failure,
    Object error,
    StackTrace stackTrace,
  ) {
    _holder.takeIf(link);
    _switchRequestedFor = null;
    _logger.warn(
      'Deep link dropped: failed $step: $link',
      error: error,
      stackTrace: stackTrace,
    );
    // Reporting is best effort: a report that can't be shown was logged
    // above, and must not end the pass loop for the links behind this one.
    try {
      _onFailure?.call(failure);
    } on Object catch (reportError, reportStackTrace) {
      _logger.warn(
        'Deep link failure could not be reported: $link',
        error: reportError,
        stackTrace: reportStackTrace,
      );
    }
  }
}
