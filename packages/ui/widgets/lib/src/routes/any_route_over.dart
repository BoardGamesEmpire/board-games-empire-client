import 'package:flutter/widgets.dart';

/// Whether any route is over the one holding [context], on its own
/// navigator or on any navigator above it, up to the root: a pop-up or a
/// page.
///
/// A route on a nested navigator, as a shell's, stays the current one on
/// that navigator while a dialog or a page is up on the root navigator
/// above it, so each enclosing route is asked in turn: the one holding
/// [context], then the one holding its navigator, and so on. False where
/// [context] is in no route, or has left the tree.
///
/// For a question asked as something happens, not in a build. Flutter
/// offers no public way to find the route holding a context without
/// depending on it, so each route asked registers a dependency on whether
/// it is current: from [context], and from each enclosing navigator's own
/// context. That one outlives [context]'s widget, and lasts while the
/// navigator does: each time its route's current state changes after, the
/// navigator tells its routes that something outside them changed, as
/// [NavigatorState.didChangeDependencies] does. Only the route's
/// `isCurrent` is depended on, the narrowest aspect there is.
bool anyRouteOver(BuildContext context) {
  BuildContext? at = context;
  while (at != null && at.mounted) {
    final current = ModalRoute.isCurrentOf(at);
    if (current == null) return false;
    if (!current) return true;
    // The navigator holding that route, whose own route is asked next.
    at = at.findAncestorStateOfType<NavigatorState>()?.context;
  }
  return false;
}
