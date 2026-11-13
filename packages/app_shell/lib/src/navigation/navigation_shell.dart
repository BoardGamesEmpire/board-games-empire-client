import 'package:app_shell/src/navigation/menu_drawer.dart';
import 'package:app_shell/src/navigation/nav_destination.dart';
import 'package:app_shell/src/router/app_router.dart' show AppRoutes;
import 'package:app_shell/src/screens/home_menu_entry.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:ui/ui.dart' show BgeNavigationMenu;
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
/// plays in full (#643). A destructive entry, sign out, runs at once.
///
/// Picking a destination is a `go` to its location, which replaces the
/// stack, unless the location already is that destination's own.
///
/// System Back closes an open drawer first. On a destination's own screen,
/// other than Home, with nothing beneath it, it goes home. Anything else is
/// the router's, and so is everything while [deferBack] says so.
class NavigationShell extends StatefulWidget {
  const NavigationShell({
    required this.destinations,
    required this.entries,
    required this.activeServerName,
    required this.location,
    required this.child,
    this.deferBack,
    super.key,
  });

  /// The app's sections, in order.
  final List<NavDestination> destinations;

  /// The menu's entries, in order.
  final List<HomeMenuEntry> entries;

  /// The active server's display name, for the menu's header, or null.
  final String? activeServerName;

  /// The location of the page on top, which decides the destination shown
  /// as current.
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

  @override
  void dispose() {
    _barFocus.dispose();
    _railFocus.dispose();
    super.dispose();
  }

  void _openDrawer() => _scaffold.currentState?.openDrawer();

  /// Goes to [destination], unless the location already is its own.
  void _go(NavDestination destination) {
    if (widget.location == destination.location) return;
    GoRouter.of(context).go(destination.location);
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
    _afterClose = null;
    _picked = false;
    if (run == null) return;
    // Called while the frame tears the drawer down; navigate after it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) run();
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
    final scaffold = _scaffold.currentState;
    if (scaffold != null && scaffold.isDrawerOpen) {
      scaffold.closeDrawer();
      return true;
    }
    final location = widget.location;
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

  /// Keeps keyboard focus on the destinations when a resize swaps the bar
  /// for the rail or back.
  ///
  /// The old form's control goes with it, and focus on it would fall to
  /// nothing. So when it had focus, the new form's [currentId] gets it,
  /// after the frame that builds it: by then the old node has gone and
  /// Flutter's own fallback has yet to run, and a request made there wins.
  ///
  /// Runs in build, while the old form's control still has focus.
  void _keepChromeFocus(_Chrome chrome, String? currentId) {
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

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final now = FocusManager.instance.primaryFocus;
      // Gone elsewhere meanwhile: the user's, not ours.
      if (!mounted || (now != null && now != focused)) return;
      _focusDestination(_focusOf(chrome), currentId);
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
      (d) => d.contains(widget.location),
    );
    final windowClass = BgeWindowClass.of(context);
    final chrome = destinations.length < 2 || current < 0
        ? _Chrome.none
        : windowClass == BgeWindowClass.compact
        ? _Chrome.bar
        : _Chrome.rail;
    _keepChromeFocus(chrome, current < 0 ? null : destinations[current].id);

    return BackButtonListener(
      onBackButtonPressed: _back,
      child: Scaffold(
        key: _scaffold,
        onDrawerChanged: _drawerChanged,
        // On iOS a swipe from the edge is the back gesture of the page on
        // top, and this drawer sits under every page (#414), so its edge
        // drag would take that swipe. Elsewhere the edge drag is how a pushed
        // screen, which shows a back arrow, reaches the menu.
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
              onEntry: (entry) => _pick(
                () => entry.onSelected(context),
                now: entry.isDestructive,
              ),
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
                        leading: IconButton(
                          icon: const Icon(Icons.menu),
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).openAppDrawerTooltip,
                          onPressed: _openDrawer,
                        ),
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
