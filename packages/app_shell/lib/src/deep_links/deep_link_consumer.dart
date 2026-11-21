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
/// After a switch, and after an add hands a link back ([holdUntilSignedIn],
/// #971), the app is still Ready from the old server until the new
/// server's sign-in outcome arrives. Until then nothing lands on the new
/// server: a pass in that window, asked for by a link arriving or by the
/// switch's own pass, leaves the link held. The outcome is [drain]: the
/// shell's authenticated signal. A server that needs sign-in leaves Ready
/// instead, and its sign-in drains later (#82). Links for other servers are
/// acted on at once, so the newest link still wins, except the link handed
/// back after an add: it waits for the added server's sign-in even when
/// that server isn't the link's (#971). There is no wait
/// when the switch lands back on the server the auth scope is still signed
/// in on, before the scope rebuilt for another: its bloc never left, so no
/// outcome would come, and the link lands at once (#985).
///
/// A switch happens once per link delivery. If a later pass finds that
/// link's server no longer active, the app has moved elsewhere since the
/// switch, and the link is dropped rather than switched to again or left to
/// land by surprise when the user returns to that server (#82). Every
/// delivery is a new request, so a link sent again, even one equal to the
/// held link, is switched to again.
///
/// An app link names no server, so it needs no lookup and no switch, and
/// lands at once unless a switch's sign-in outcome is still awaited (#126).
/// Web passes no lookup and no orchestrator (single-origin) and holds only
/// app links: the location the page was loaded at, which the router writes
/// to the slot on its first redirect (#83). A server link would go straight
/// to its location there, if one arrived.
class DeepLinkConsumer {
  DeepLinkConsumer({
    required this._holder,
    required this._isReady,
    required this._lookup,
    required this._orchestrator,
    required this._go,
    this._onFailure,
    bool Function(String localId)? isSignedInOn,
    BgeLogger? logger,
  }) : _isSignedInOn = isSignedInOn ?? _signedInNowhere,
       _logger = logger ?? BgeLogger('bge.shell.deep_links');

  static bool _signedInNowhere(String _) => false;

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
  /// so the shell can say so (#984). Not called for the deliberate drop,
  /// for a server not added here, for a link a newer one replaced while it
  /// waited, or after [dispose].
  final void Function(DeepLinkFailure failure)? _onFailure;

  /// Whether the auth scope's mounted bloc is signed in on the server with
  /// this local id (#985). Asked only after a switch, which web never makes,
  /// so web passes none and it answers false.
  final bool Function(String localId) _isSignedInOn;
  final BgeLogger _logger;

  bool _disposed = false;
  bool _draining = false;
  bool _again = false;

  /// The link whose server this consumer last made active, or an add did
  /// ([holdUntilSignedIn]), while that delivery of it is still held. Met
  /// again while that server isn't active, the link is dropped: the switch
  /// happened, and the app has moved off it since. A link handed back whose
  /// server isn't the one added is never dropped for this: it names no
  /// server here, so the mark only holds it through the added server's
  /// wait, and once that ends it shows the unknown-server screen, even when
  /// the app has left the added server (#971). A link arriving clears it.
  ServerDeepLink? _switchRequestedFor;

  /// The local id of the server made active for [_switchRequestedFor], by
  /// the switch or by the add. Read only while that is set.
  String? _switchedToLocalId;

  /// The local id of a server this consumer switched to that the auth
  /// scope wasn't signed in on, or one a link was handed back for after its
  /// add ([holdUntilSignedIn]), until a sign-in outcome arrives ([drain]).
  /// The hand-back sets it even when a newer link keeps the handed-back one
  /// out of the slot (#971).
  ///
  /// While it is the active server, neither that server's links nor app
  /// links land, because the page an app link opens reads the active
  /// server, and would show the old one's (#126). Nor does the handed-back
  /// link when its server isn't the one added: its unknown-server screen
  /// would leave that server's sign-in (#971). Links for other servers, and
  /// any other link for a server not added here, still act at once. A
  /// switch back to the server the scope is still signed in on never sets
  /// it (#985), so after a round trip it can name a server the app has
  /// since left; it holds links only for the active server, and the next
  /// outcome clears it.
  String? _awaitingSignInOn;

  /// Whether the sign-in outcome of a server switched to, or of one added
  /// with a link handed back ([holdUntilSignedIn]), is still awaited and
  /// [activeServerId] is that server. Web has no orchestrator, so no active
  /// server, and it is false there.
  bool _awaitingSignInOnActive(String? activeServerId) {
    final awaiting = _awaitingSignInOn;
    return awaiting != null && awaiting == activeServerId;
  }

  /// Listens to the holder and drains once, for a link held before start.
  void start() {
    _holder.addListener(_onLinkArrived);
    unawaited(_requestPass());
  }

  /// Drains the slot on the shell's authenticated signal: the active server
  /// has a session. That is also how the app enters Ready, so it covers a
  /// link held through bootstrap and sign-in, and it is the sign-in outcome
  /// a server switch waits for, as does a link handed back after an add
  /// ([holdUntilSignedIn]). Links that arrive drain on their own.
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

  /// Holds [link] until the server with [localServerId] has a sign-in
  /// outcome, then lands it as any held link would, on the shell's next
  /// [drain] (#971).
  ///
  /// For a link handed back after its server was added from it. After the
  /// add, the app can still be Ready from the old server while the added
  /// one is active and signed out, so a link put straight into the slot
  /// would land at once, before sign-in, and be lost. This sets the same
  /// wait a switch sets, then holds the link.
  ///
  /// Call it only once the added server is the active one. Any [drain]
  /// after the call clears the wait, as it does a switch's.
  ///
  /// When the server added is the link's, the add counts as this link's
  /// switch: if the app leaves the added server before the link lands, the
  /// link is dropped, not switched back to (#82).
  ///
  /// The server added can be another one than the link names, when the user
  /// changed the address. The link still waits for that server's sign-in,
  /// and the drain that ends the wait shows the unknown-server screen, as
  /// for any link whose server isn't added. It does so even when the app has
  /// left the added server by then: the link names no server here, so
  /// there is no switch to have moved off.
  ///
  /// When the slot already holds a link, that one arrived later, and wins:
  /// [link] isn't put back, and the log says so. The wait is set all the
  /// same, since a newer link for the added server would otherwise land at
  /// once and be lost in the same way. Under the wait, the newer link:
  /// - for the added server is held until its sign-in. A pass for it
  ///   already in flight reads the wait after its lookup, so it holds the
  ///   link too;
  /// - that is an app link is held too, as after a switch;
  /// - for another registered server still switches to it;
  /// - for a server not added here still shows the unknown-server screen at
  ///   once. Only the handed-back link waits in that case.
  ///
  /// The add doesn't count as the newer link's switch, so if the app leaves
  /// the added server before its sign-in, a newer link for that server is
  /// switched back to, as any link arriving for it would be.
  ///
  /// The exception is a newer link whose switch has already been made, to
  /// another server than the one added. The add has since moved the app off
  /// that server, so the next pass would drop it as it drops any switched
  /// link the app has left. [link] takes its place instead, so the user's
  /// last step, the add, still opens something. Not while a pass runs: it
  /// may be that link's own, inside its switch.
  ///
  /// Does nothing after [dispose].
  void holdUntilSignedIn(ServerDeepLink link, String localServerId) {
    if (_disposed) return;
    // The wait first: setting the link triggers a pass at once, through
    // the holder's listener, and that pass must see it. A pass already in
    // flight for a newer link sees it after its own await.
    _awaitingSignInOn = localServerId;
    final held = _holder.peek;
    if (held != null) {
      final leftBehind =
          !_draining &&
          _switchRequestedFor == held &&
          _switchedToLocalId != localServerId;
      if (!leftBehind) {
        _logger.info(
          'Deep link handed back after an add, discarded for a newer one: '
          '$link',
        );
        return;
      }
      _logger.info(
        'Deep link dropped: the add left the server it was switched to, '
        'and the link handed back takes its place: $held',
      );
    }
    _holder.set(link);
    // After the link: its arrival forgets any earlier switch.
    _switchRequestedFor = link;
    _switchedToLocalId = localServerId;
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
    final held = _holder.peek;
    // A pending switch belongs to the link it was made for, while that link
    // is held. Once another replaces it or the slot empties, the same link
    // sent again is a new request, not one the app has moved off.
    if (_switchRequestedFor != held) _switchRequestedFor = null;
    if (_disposed || !_isReady() || held == null) return;

    final ServerDeepLink link;
    switch (held) {
      case AppDeepLink():
        // The page an app link opens reads the active server, so it waits
        // out a switched-to server's sign-in outcome, as that server's own
        // links do (#126).
        if (_awaitingSignInOnActive(_orchestrator()?.activeServerId)) return;
        _land(held, held.location);
        return;
      case ServerDeepLink():
        link = held;
    }

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
      // Handed back after an add, and the server added at the address the
      // user typed is another one (#971). Its sign-in comes first: routing
      // to the unknown-server screen now would leave it, and the app, with
      // no sign-in shown. Its outcome drains, and the screen shows then.
      if (_switchRequestedFor == link &&
          _awaitingSignInOnActive(orchestrator.activeServerId)) {
        return;
      }
      _holder.takeIf(link);
      _logger.info('Deep link names a server not added here: $link');
      _go(AppRoutes.deepLinkUnknownServerOf(link.location));
      return;
    }

    if (localId == orchestrator.activeServerId) {
      // Switched to, and its sign-in outcome isn't known yet: landing now
      // would take the link from a sign-in that may still need it.
      if (_awaitingSignInOnActive(localId)) return;
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
    _switchedToLocalId = localId;
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
    // Switched back to the server the auth scope is still signed in on,
    // before the scope rebuilt for the one in between: its bloc stays
    // mounted, so no sign-in outcome is coming, and a wait set here would
    // hold every later link for that server (#985). If this link is no
    // longer the one to act on, the newer link's arrival has already queued
    // a pass of its own, and a Ready regained drains.
    if (_isSignedInOn(localId)) {
      if (!_stillCurrent(link)) return;
      _switchRequestedFor = null;
      _land(link, link.location);
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
    // A newer link replaced this one during the await, so the user is
    // waiting on that one, and an error for this one would show over it as
    // it lands. After dispose, nothing is reported either.
    final superseded = _disposed || _holder.peek != link;
    _holder.takeIf(link);
    _switchRequestedFor = null;
    _logger.warn(
      'Deep link dropped: failed $step: $link',
      error: error,
      stackTrace: stackTrace,
    );
    if (superseded) return;
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
