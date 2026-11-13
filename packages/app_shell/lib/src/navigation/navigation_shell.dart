import 'dart:async';

import 'package:app_shell/src/navigation/menu_drawer.dart';
import 'package:app_shell/src/navigation/nav_destination.dart';
import 'package:app_shell/src/router/app_router.dart' show AppRoutes;
import 'package:app_shell/src/screens/home_menu_entry.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:ui/ui.dart' show BgeMenuButton, BgeNavigationMenu;
import 'package:ui_tokens/ui_tokens.dart'
    show BgeNavigationFocus, BgeWindowClass;

/// What carries the destinations on screen.
enum _Chrome { none, bar, rail }

/// The navigation chrome above every signed-in page (#414).
///
/// Shows [destinations] in a [NavigationBar] along the bottom of a compact
/// window, and in a [NavigationRail] at the start of a medium or expanded
/// one, whose labels show for the selected destination only at medium and
/// for every destination at expanded. The rail's top holds the menu button;
/// elsewhere the page shows it, through [BgeNavigationMenu]. The bar or rail
/// shows only with two or more destinations and the [location] inside one
/// of them. Where neither shows, the menu lists the destinations instead.
///
/// The menu is a [MenuDrawer] holding [entries]. A pick in it closes the
/// drawer and runs once the drawer has gone, so a pushed page's transition
/// plays in full (#643). A destructive entry, sign out, runs at once. An
/// entry that opens a screen pushes it, unless that screen is already the
/// page on top.
///
/// Picking a destination is a `go` to its location, which replaces the
/// stack, unless that destination's own screen is already the only page.
///
/// System Back closes a dialog or pop-up over the shell first: the shell
/// passes it to the router. Then it closes an open drawer, and drops a
/// pick still waiting for the drawer to go. On a destination's own screen,
/// other than Home, with nothing beneath it, it goes home. Anything else is
/// the router's.
/// While [deferBack] says so, every press passes the shell by, to the
/// handler registered before it, then the router. Where the browser owns
/// Back ([browserOwnsBack]), browser Back passes the shell by too, and the
/// shell drops a waiting pick when the location changes under it.
///
/// An open drawer closes when the location changes by any other way than
/// a pick, such as browser Back or a `go` of the app's own: it was opened
/// over a page that has gone. Focus then goes to the menu button the new
/// screen shows, the rail's or the page's, or stays on the page (#611).
class NavigationShell extends StatefulWidget {
  const NavigationShell({
    required this.destinations,
    required this.entries,
    required this.activeServerName,
    required this.location,
    required this.child,
    this.deferBack,
    this.browserOwnsBack = false,
    super.key,
  });

  /// The app's sections, in order.
  final List<NavDestination> destinations;

  /// The menu's entries, in order.
  final List<HomeMenuEntry> entries;

  /// The active server's display name, for the menu's header, or null.
  final String? activeServerName;

  /// The location of the page on top, its query included. Its path decides
  /// the destination shown as current; the whole of it tells one browser
  /// history entry from another, as `/games?sort=newest` from `/games`
  /// (#611).
  final String location;

  /// The pages: the navigation route's nested navigator.
  final Widget child;

  /// Whether System Back belongs, for now, to something over the app that
  /// takes it through a handler of its own, such as a notice the user must
  /// acknowledge. Asked on each press; while it says so the shell lets every
  /// press pass.
  ///
  /// The shell's handler takes priority over every one registered before
  /// it, so one that came up before the shell would otherwise never hear
  /// Back while the shell is there.
  final bool Function()? deferBack;

  /// Whether the browser's own Back is the way back, as on the web (#611).
  ///
  /// The pages hear of it through [BgeNavigationMenu.browserOwnsBack], and
  /// show no in-app back arrow. Browser Back reaches the router as a new
  /// location, not as System Back, so the shell never hears it either: a
  /// pick still waiting for the drawer to go is dropped when the location
  /// changes under it instead, as System Back drops it.
  final bool browserOwnsBack;

  /// Key on the [NavigationBar], for tests.
  static const Key barKey = Key('nav_bar');

  /// Key on the [NavigationRail], for tests.
  static const Key railKey = Key('nav_rail');

  /// Per-destination key on the bar's and the rail's controls:
  /// `nav_destination_<id>`. The bar's sits on its [NavigationDestination],
  /// the rail's on its icon, since a rail destination is no widget.
  static Key destinationKey(String id) => Key('nav_destination_$id');

  @override
  State<NavigationShell> createState() => _NavigationShellState();
}

class _NavigationShellState extends State<NavigationShell> {
  final _scaffold = GlobalKey<ScaffoldState>(debugLabel: 'navigation shell');

  /// The pick waiting for the drawer to go, or null.
  VoidCallback? _afterClose;

  /// Whether a pick has closed the drawer. Another pick is ignored until
  /// the drawer has gone.
  bool _picked = false;

  /// Whether the page the open drawer was opened over has gone, and the
  /// menu button that opened it with it. The drawer then has nothing to
  /// hand focus back to as it goes ([_focusMenuButton]).
  bool _openerGone = false;

  /// What the last build showed the destinations in.
  _Chrome _shown = _Chrome.none;

  /// Around the bar and the rail, to tell whether focus is in one. Neither
  /// takes focus itself.
  final _barFocus = FocusNode(
    debugLabel: 'navigation bar',
    canRequestFocus: false,
    skipTraversal: true,
  );
  final _railFocus = FocusNode(
    debugLabel: 'navigation rail',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// The destination whose control in the bar or the rail last took focus,
  /// for a resize to hand focus to the same one in the other form.
  ///
  /// Noted as focus moves, since a resize reads it in build, where the
  /// rail's control, which its destination's key sits below, can't be
  /// searched.
  String? _focusedId;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_noteFocusedId);
  }

  @override
  void didUpdateWidget(NavigationShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The whole location, not its path: browser Back from `/games` to
    // `/games?sort=newest` changes only the query.
    if (widget.location == oldWidget.location) return;
    // Browser Back, or Forward, while a pick waits for the drawer to go
    // (#611). It reaches the router, not [_back], and reads as "never
    // mind", as System Back does there. The pick itself runs only once the
    // drawer has gone, so this change is not its own. The page the drawer
    // was opened over went, and its menu button with it. Natively the
    // user's Back goes through [_back], and a location that changes on its
    // own, as when a page leaves once its work is done, leaves the pick
    // standing.
    if (widget.browserOwnsBack && _afterClose != null) {
      _afterClose = null;
      _openerGone = true;
    }
    // An open drawer with no pick made: the page went from under it by some
    // other way than the drawer, browser Back or a `go` of the app's own.
    // The drawer was opened over that page, and doesn't stay over another.
    final scaffold = _scaffold.currentState;
    if (!_picked && scaffold != null && scaffold.isDrawerOpen) {
      _openerGone = true;
      scaffold.closeDrawer();
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_noteFocusedId);
    _barFocus.dispose();
    _railFocus.dispose();
    super.dispose();
  }

  void _noteFocusedId() {
    final focused = FocusManager.instance.primaryFocus;
    if (focused == null || _shown == _Chrome.none) return;
    final chrome = _focusOf(_shown);
    if (!chrome.hasFocus) return;
    _focusedId = widget.destinations
        .where(
          (d) => _marks(focused, NavigationShell.destinationKey(d.id), chrome),
        )
        .firstOrNull
        ?.id;
  }

  /// The path of [NavigationShell.location], without its query.
  String get _path => Uri.parse(widget.location).path;

  void _openDrawer() => _scaffold.currentState?.openDrawer();

  /// Gives focus to the menu button the screen now shows, the rail's or the
  /// page's, once a drawer whose opener went ([_openerGone]) has gone too
  /// (#611).
  ///
  /// A drawer that closes hands focus back to what opened it, but that
  /// button left with its page, and focus falls to the page that replaced
  /// it. The menu button there stands in for it. With none, as on a page
  /// under a section on the web, focus stays on that page, and Tab goes on
  /// from its top.
  ///
  /// Runs after the frame the drawer left in, as [_keepChromeFocus] does.
  /// Focus on none, or on a scope in the shell's, has fallen there. Focus
  /// on a control was put there since, by the user, and focus in another
  /// route's scope belongs to that route, such as a dialog that came up
  /// over the shell meanwhile: both are left alone.
  void _focusMenuButton() {
    final now = FocusManager.instance.primaryFocus;
    final scope = FocusScope.of(context, createDependency: false);
    final fallen =
        now == null ||
        (now is FocusScopeNode &&
            (now == scope || now.ancestors.contains(scope)));
    if (!fallen) return;
    scope.traversalDescendants
        .where((node) => _isMenuButton(node) && _onCurrentPage(node, scope))
        .firstOrNull
        ?.requestFocus();
  }

  static bool _isMenuButton(FocusNode node) =>
      node.context?.findAncestorWidgetOfExactType<BgeMenuButton>() != null;

  /// Whether [node] is on the page on top, or on the chrome, rather than on
  /// a page beneath: a route's scope skips traversal while the route is not
  /// the current one. The walk up stops at [scope], the shell's.
  static bool _onCurrentPage(FocusNode node, FocusScopeNode scope) => node
      .ancestors
      .takeWhile((ancestor) => ancestor != scope)
      .every(
        (ancestor) => ancestor is! FocusScopeNode || !ancestor.skipTraversal,
      );

  /// Goes to [destination], unless its own screen is already the only page.
  ///
  /// A pushed copy of it, as home's See all pushes Games, still goes: the
  /// `go` replaces the whole stack with the destination's own screen (#414).
  void _go(NavDestination destination) {
    final router = GoRouter.of(context);
    if (_path == destination.location && !router.canPop()) return;
    router.go(destination.location);
  }

  /// Pushes the screen [entry] opens, unless it is already the page on top,
  /// or runs the entry's own action.
  void _runEntry(HomeMenuEntry entry) {
    final location = entry.location;
    if (location == null) {
      entry.onSelected!(context);
    } else if (location != _path) {
      unawaited(GoRouter.of(context).push<void>(location));
    }
  }

  /// Closes the drawer for a pick, and runs [run] once it has gone, or at
  /// once when [now].
  void _pick(VoidCallback run, {bool now = false}) {
    if (_picked) return;
    _picked = true;
    _scaffold.currentState?.closeDrawer();
    if (now) {
      run();
    } else {
      _afterClose = run;
    }
  }

  /// The drawer's close animation has ended and the drawer left the tree.
  ///
  /// This is the moment a pick runs, not `onDrawerChanged(false)`: Flutter
  /// reports the close as it starts, in the same call that starts the
  /// animation, so a push from there would play under the drawer (#643).
  void _drawerGone() {
    final run = _afterClose;
    final openerGone = _openerGone;
    _afterClose = null;
    _picked = false;
    _openerGone = false;
    // Called while the frame tears the drawer down; act after it. A pick
    // made as the drawer closed goes where it goes, and focus with it.
    if (run == null && !openerGone) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (run != null) {
        run();
      } else {
        _focusMenuButton();
      }
    });
  }

  void _drawerChanged(bool open) {
    // A tap on the drawer as it closes stops it, and Flutter opens it again
    // from past halfway. The pick stands, so it closes again, and the
    // second tap's own pick was ignored: picking twice runs once.
    if (open && _picked) _scaffold.currentState?.closeDrawer();
  }

  Future<bool> _back() async {
    if (widget.deferBack?.call() ?? false) return false;
    // A dialog or pop-up on a navigator above the shell's is what Back
    // closes, even with the drawer open beneath it.
    if (_underModal()) return false;
    // The pick has closed the drawer already, so Back while it closes reads
    // as "never mind": the pick is dropped, and Back does nothing else.
    if (_afterClose != null) {
      _afterClose = null;
      return true;
    }
    final scaffold = _scaffold.currentState;
    if (scaffold != null && scaffold.isDrawerOpen) {
      scaffold.closeDrawer();
      return true;
    }
    final location = _path;
    final router = GoRouter.of(context);
    // `canPop` is true while a dialog or pop-up is up on the root
    // navigator, so the router closes that first.
    if (location != AppRoutes.home &&
        widget.destinations.any((d) => d.location == location) &&
        !router.canPop()) {
      router.go(AppRoutes.home);
      return true;
    }
    return false;
  }

  /// Whether a route is over the shell on a navigator above it, such as a
  /// dialog on the root navigator.
  ///
  /// The shell's own route is the current one on its navigator whatever the
  /// root navigator holds, as that navigator may be another shell's, so each
  /// enclosing route is asked in turn, up to the root.
  bool _underModal() {
    BuildContext? at = context;
    while (at != null && at.mounted) {
      final route = ModalRoute.of(at);
      if (route == null) return false;
      if (!route.isCurrent) return true;
      at = route.navigator?.context;
    }
    return false;
  }

  /// Keeps keyboard focus on the destinations when a resize swaps the bar
  /// for the rail or back.
  ///
  /// The old form's control goes with it, and focus on it would fall to
  /// nothing. So when it had focus, the same destination's control in the
  /// new form, [_focusedId]'s, gets it, after the frame that builds it: by
  /// then the old node has gone and Flutter's own fallback has yet to run,
  /// and a request made there wins. Focus on a control that is no
  /// destination, such as the rail's menu button, goes to [currentId]'s.
  ///
  /// Runs in build, while the old form's control still has focus.
  void _keepChromeFocus(
    _Chrome chrome,
    List<NavDestination> destinations,
    String? currentId,
  ) {
    final before = _shown;
    _shown = chrome;
    if (before == chrome ||
        before == _Chrome.none ||
        chrome == _Chrome.none ||
        currentId == null ||
        !_focusOf(before).hasFocus) {
      return;
    }
    final focused = FocusManager.instance.primaryFocus;
    final noted = _focusedId;
    final focusedId = destinations.any((d) => d.id == noted) ? noted : null;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final now = FocusManager.instance.primaryFocus;
      // Gone elsewhere meanwhile: the user's, not ours.
      if (!mounted || (now != null && now != focused)) return;
      _focusDestination(_focusOf(chrome), focusedId ?? currentId);
    });
  }

  FocusNode _focusOf(_Chrome chrome) =>
      chrome == _Chrome.bar ? _barFocus : _railFocus;

  /// Focuses destination [id]'s control in [chrome], the bar's or the rail's
  /// node, or its first control if it has no such destination.
  void _focusDestination(FocusNode chrome, String id) {
    final mark = NavigationShell.destinationKey(id);
    final controls = chrome.traversalDescendants;
    (controls.where((node) => _marks(node, mark, chrome)).firstOrNull ??
            controls.firstOrNull)
        ?.requestFocus();
  }

  /// Whether [node] is the control of the destination [mark] keys. The bar
  /// keys the destination, above the control's node, and the rail keys the
  /// icon, below it. The walk up stops at [chrome].
  static bool _marks(FocusNode node, Key mark, FocusNode chrome) {
    var found = false;
    node.context?.visitAncestorElements((element) {
      found = element.widget.key == mark;
      return !found && element != chrome.context;
    });
    void visit(Element element) {
      if (found) return;
      found = element.widget.key == mark;
      if (!found) element.visitChildren(visit);
    }

    node.context?.visitChildElements(visit);
    return found;
  }

  @override
  Widget build(BuildContext context) {
    final destinations = widget.destinations;
    final current = destinations.indexWhere(
      (d) => d.contains(_path),
    );
    final windowClass = BgeWindowClass.of(context);
    final chrome = destinations.length < 2 || current < 0
        ? _Chrome.none
        : windowClass == BgeWindowClass.compact
        ? _Chrome.bar
        : _Chrome.rail;
    _keepChromeFocus(
      chrome,
      destinations,
      current < 0 ? null : destinations[current].id,
    );

    return BackButtonListener(
      onBackButtonPressed: _back,
      child: Scaffold(
        key: _scaffold,
        onDrawerChanged: _drawerChanged,
        // On iOS a swipe from the edge is the back gesture of the page on
        // top, and this drawer sits under every page (#414), so its edge
        // drag would take that swipe. Elsewhere the edge drag is how a page
        // with no menu button of its own reaches the menu: natively a pushed
        // screen, which shows a back arrow in its place, and on the web a
        // page under a section, which shows nothing there (#611).
        drawerEnableOpenDragGesture:
            Theme.of(context).platform != TargetPlatform.iOS,
        drawer: _DrawerGone(
          onGone: _drawerGone,
          child: _unselectable(
            MenuDrawer(
              destinations: chrome == _Chrome.none ? destinations : const [],
              selectedId: current < 0 ? null : destinations[current].id,
              entries: widget.entries,
              activeServerName: widget.activeServerName,
              onDestination: (destination) => _pick(() => _go(destination)),
              onEntry: (entry) =>
                  _pick(() => _runEntry(entry), now: entry.isDestructive),
            ),
          ),
        ),
        bottomNavigationBar: chrome == _Chrome.bar
            ? _chrome(
                _barFocus,
                NavigationBar(
                  key: NavigationShell.barKey,
                  selectedIndex: current,
                  onDestinationSelected: (index) => _go(destinations[index]),
                  destinations: [
                    for (final destination in destinations)
                      NavigationDestination(
                        key: NavigationShell.destinationKey(destination.id),
                        icon: Icon(destination.icon),
                        selectedIcon: Icon(destination.selectedIcon),
                        label: destination.label,
                      ),
                  ],
                ),
              )
            : null,
        body: BgeNavigationMenu(
          onOpen: _openDrawer,
          offersPageButton: chrome != _Chrome.rail,
          browserOwnsBack: widget.browserOwnsBack,
          // The same shape in every form, so a resize across a breakpoint,
          // or the rail going on a screen the menu opens, never remounts
          // the pages or their messenger.
          child: Row(
            children: [
              if (chrome == _Chrome.rail)
                _chrome(
                  _railFocus,
                  // A rail has no focus overlay of its own and reads the
                  // theme's `focusColor`, which the app's theme leaves
                  // alone: set here, it reaches the rail only (#644).
                  Theme(
                    data: Theme.of(context).copyWith(
                      focusColor: BgeNavigationFocus.railFill(
                        Theme.of(context).colorScheme,
                      ),
                    ),
                    // Its own traversal group, so Tab walks the rail as it
                    // is drawn: the menu button, then the destinations top
                    // to bottom. Left to the page's policy, the full-height
                    // pages beside it share a reading-order band with every
                    // stop, and the rail came out as Collection, Events,
                    // Home, Games, then the menu button (#414).
                    child: FocusTraversalGroup(
                      child: NavigationRail(
                        key: NavigationShell.railKey,
                        selectedIndex: current,
                        labelType: windowClass == BgeWindowClass.expanded
                            ? NavigationRailLabelType.all
                            : NavigationRailLabelType.selected,
                        // A landscape phone, or large text, is shorter than the
                        // destinations.
                        scrollable: true,
                        leading: BgeMenuButton(onPressed: _openDrawer),
                        onDestinationSelected: (index) =>
                            _go(destinations[index]),
                        destinations: [
                          for (final destination in destinations)
                            NavigationRailDestination(
                              icon: KeyedSubtree(
                                key: NavigationShell.destinationKey(
                                  destination.id,
                                ),
                                child: Icon(destination.icon),
                              ),
                              selectedIcon: KeyedSubtree(
                                key: NavigationShell.destinationKey(
                                  destination.id,
                                ),
                                child: Icon(destination.selectedIcon),
                              ),
                              label: Text(destination.label),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              Expanded(
                key: const ValueKey('navigation_shell_pages'),
                // Every route's barrier blocks the semantics of what was
                // painted before it, up to the nearest container, and the
                // rail is painted before the pages. Without a container
                // here a screen reader never reaches the rail.
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  // Below the Scaffold, so the body's own insets carry through.
                  child: Builder(
                    builder: (context) {
                      final rail = chrome == _Chrome.rail;
                      final ltr =
                          Directionality.of(context) == TextDirection.ltr;
                      // The rail keeps a cutout on its side clear itself, so
                      // the pages beside it would inset a second time. Always
                      // here, removing nothing without a rail, so the pages
                      // keep their place in the tree.
                      return MediaQuery.removePadding(
                        context: context,
                        removeLeft: rail && ltr,
                        removeRight: rail && !ltr,
                        // The pages' own, so a page's SnackBar shows in the
                        // page's Scaffold, above the bar, and moves the page's
                        // floating button out of its way. The shell's
                        // Scaffold would otherwise take it, under the button
                        // (#414).
                        child: ScaffoldMessenger(child: widget.child),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Takes [child] out of the app's text-selection region.
  ///
  /// Nobody selects a menu label, and a press-drag on one should navigate,
  /// not start a selection. So this stays after Flutter fixes
  /// flutter/flutter#192081, which a press-drag on a drawer item could reach
  /// (#625): `handleClearSelection` iterating a scrolling container's
  /// selectables while one unregisters. Out of the region, the drawer's
  /// text never registers, so that loop never holds it.
  ///
  /// No widget test reaches the throwing path. The loop throws only when a
  /// selectable unregisters while the clear is being dispatched, and the
  /// drawer's text registers and unregisters only as the tree is built,
  /// laid out or torn down, never inside a dispatch. Flutter's own
  /// reproduction needs a hand-written delegate that removes its child on a
  /// clear. A mouse drag on the drawer without this wrap, with the drawer
  /// changing and closing mid-drag, threw nothing.
  static Widget _unselectable(Widget child) =>
      SelectionContainer.disabled(child: child);

  /// The bar or the rail, out of the selection region, under [focus].
  static Widget _chrome(FocusNode focus, Widget child) => _unselectable(
    Focus(focusNode: focus, includeSemantics: false, child: child),
  );
}

/// Calls [onGone] when it leaves the tree.
///
/// A Scaffold builds its drawer only while the drawer is on screen, so,
/// around the drawer, this leaves the tree in the frame its close animation
/// ends.
class _DrawerGone extends StatefulWidget {
  const _DrawerGone({required this.onGone, required this.child});

  final VoidCallback onGone;
  final Widget child;

  @override
  State<_DrawerGone> createState() => _DrawerGoneState();
}

class _DrawerGoneState extends State<_DrawerGone> {
  @override
  void dispose() {
    widget.onGone();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
