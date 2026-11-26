import 'dart:async';

/// Answers whether the page that makes an API key may be taken away
/// (#1028).
///
/// The page refuses a pop of its own route while it shows a new key's
/// secret. What it can't refuse by itself is its route being taken away
/// without a pop, as a router does for the browser's Back and for a move to
/// another location. Whatever holds the route asks [mayLeave] first, and
/// keeps the route on a false.
///
/// The page attaches itself while it is mounted. With no page attached
/// there is nothing to lose, and [mayLeave] says yes at once.
///
/// One guard serves one route. It knows nothing of routers: the caller
/// makes it, hands it to `ApiKeyCreateScreen`, and asks it from wherever
/// the route's leaving is decided.
class ApiKeyCreateLeaveGuard {
  FutureOr<bool> Function()? _ask;

  /// Whether the page may go. True at once when no page is attached, or the
  /// page has nothing to lose. Otherwise what the page answers: at once to
  /// hold a create that is on its way, and once the user has answered when
  /// it has to ask them.
  FutureOr<bool> mayLeave() => _ask?.call() ?? true;

  /// Makes [ask] what [mayLeave] asks, and returns what takes it away
  /// again. The page attaches as it mounts and detaches as it goes.
  ///
  /// The detach does nothing once another page has attached: a page that
  /// takes another's place mounts before the one it replaces has gone, and
  /// the old page's going must not undo it.
  void Function() attach(FutureOr<bool> Function() ask) {
    _ask = ask;
    return () {
      if (identical(_ask, ask)) _ask = null;
    };
  }
}
