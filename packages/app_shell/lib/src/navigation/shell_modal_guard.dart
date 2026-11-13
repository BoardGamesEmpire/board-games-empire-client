import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Takes a modal on the root navigator down with the navigation shell page
/// it was opened over (#414).
///
/// A route with no page of its own, such as `showDialog`'s, belongs to the
/// page beneath it on its navigator, and Flutter removes it when that page
/// leaves. The app's modals go on the root navigator, so their barrier
/// covers the shell's bar or rail, while every signed-in page is on the
/// shell's nested navigator. On the root navigator the page beneath a modal
/// is the auth shell's, which stays while signed in, so the modal would
/// outlive its page: browser Back, a `go` or the sign-out redirect would
/// leave it over a page it doesn't belong to.
///
/// So the guard notes the shell's top page as each root modal opens, and
/// removes the modal once that page leaves the shell's navigator, or the
/// shell itself leaves. A page go_router builds from the location is keyed
/// by its route's pattern, so a `go` between two ids of one route, such as
/// from one household to another, keeps the page and only rebuilds it, and
/// the navigator reports nothing. The guard reads that as a leave too: the
/// opener's key now carries other arguments. Either way the guard removes
/// the modal at once, with [NavigatorState.removeRoute], where Flutter
/// would have popped the top one with its exit animation: the page has left
/// on another navigator, so a modal fading out on this one would linger
/// over the page that took its place. A page pushed over that page is not
/// a leave: a pop-up that opened it waits for it to arrive and removes
/// itself (#707). A modal opened while there is no shell page, such as over
/// the sign-in screen, is left to Flutter.
///
/// An observer attaches to one navigator, so there are two: [rootObserver]
/// for the router's own observers, and [shellObserver] for the navigation
/// shell's `ShellRoute`. [wrapShell] wraps what that `ShellRoute` builds,
/// to hear the shell leave. One guard per router.
class ShellModalGuard {
  /// The observer for the root navigator, which the modals are on.
  late final NavigatorObserver rootObserver = _RootObserver(this);

  /// The observer for the navigation shell's navigator, which the pages
  /// are on.
  late final NavigatorObserver shellObserver = _ShellObserver(this);

  /// Each open modal the guard owns, with the shell page it was opened
  /// over.
  final Map<Route<dynamic>, Page<Object?>> _openers = {};

  /// Wraps [shell], what the navigation shell's `ShellRoute` builds, so the
  /// guard hears it leave, as it is disposed exactly when that route leaves,
  /// and hears each change to the shell's pages, as the route builds it
  /// again for each.
  Widget wrapShell(Widget shell) => _ShellLifetime(guard: this, child: shell);

  void _opened(Route<dynamic> modal) {
    final page = shellObserver.navigator?.widget.pages.lastOrNull;
    if (page != null) _openers[modal] = page;
  }

  void _closed(Route<dynamic> modal) => _openers.remove(modal);

  void _pageLeft(Route<dynamic> route) {
    if (route.settings case Page(:final key?)) {
      _removeWhere((page) => page.key == key);
    }
  }

  void _shellLeft() => _removeWhere((_) => true);

  /// The shell's pages may have changed: after the frame, by when its
  /// navigator holds them, removes the modals whose opener has no page left
  /// with its key and its arguments. A page that left is the observer's,
  /// so this finds the ones go_router rebuilt in place for another location.
  void _shellRebuilt() {
    if (_openers.isEmpty) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final pages = shellObserver.navigator?.widget.pages;
      if (pages == null) return;
      _removeWhere(
        (opener) => !pages.any(
          (page) =>
              page.key == opener.key &&
              _sameArguments(page.arguments, opener.arguments),
        ),
      );
    }, debugLabel: 'ShellModalGuard.shellRebuilt');
  }

  /// The app's pages carry their path and query parameters as a map.
  static bool _sameArguments(Object? a, Object? b) =>
      a is Map && b is Map ? mapEquals(a, b) : a == b;

  /// Removes the modals opened over a page that [test] accepts, after the
  /// current frame.
  ///
  /// [NavigatorState.removeRoute] can't run while a navigator is updating
  /// its history, which is where an observer is called from, nor while the
  /// tree is being finalised, which is where the shell is disposed.
  void _removeWhere(bool Function(Page<Object?> opener) test) {
    final modals = [
      for (final MapEntry(key: modal, value: page) in _openers.entries)
        if (test(page)) modal,
    ];
    if (modals.isEmpty) return;
    modals.forEach(_openers.remove);
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        // The top one first, as they would have gone.
        for (final modal in modals.reversed) {
          if (modal.isActive) modal.navigator!.removeRoute(modal);
        }
      }, debugLabel: 'ShellModalGuard.removeRoute')
      // A post-frame callback asks for no frame of its own.
      ..ensureVisualUpdate();
  }
}

class _RootObserver extends NavigatorObserver {
  _RootObserver(this._guard);

  final ShellModalGuard _guard;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // go_router reports every nested navigator's routes to the router's
    // observers too: only the root's own modals are the guard's.
    if (identical(route.navigator, navigator) && route.settings is! Page) {
      _guard._opened(route);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _guard._closed(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _guard._closed(route);
}

/// Hears a shell page leave: popped (browser Back to a pushed page's
/// entry), or completed and removed (a `go`, a replacement, browser Back to
/// an entry the router builds afresh). go_router reports no replace.
class _ShellObserver extends NavigatorObserver {
  _ShellObserver(this._guard);

  final ShellModalGuard _guard;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _guard._pageLeft(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      _guard._pageLeft(route);
}

class _ShellLifetime extends StatefulWidget {
  const _ShellLifetime({required this.guard, required this.child});

  final ShellModalGuard guard;
  final Widget child;

  @override
  State<_ShellLifetime> createState() => _ShellLifetimeState();
}

class _ShellLifetimeState extends State<_ShellLifetime> {
  @override
  void didUpdateWidget(_ShellLifetime oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.guard._shellRebuilt();
  }

  @override
  void dispose() {
    widget.guard._shellLeft();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
