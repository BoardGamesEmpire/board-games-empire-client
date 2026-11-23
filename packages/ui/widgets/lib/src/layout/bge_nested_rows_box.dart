import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show clampDouble, defaultTargetPlatform, precisionErrorTolerance;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
import 'package:flutter/services.dart'
    show HardwareKeyboard, KeyRepeatEvent, KeyUpEvent, LogicalKeyboardKey;
import 'package:ui/src/focus/bge_focus_ring.dart';
import 'package:ui/src/layout/bge_outlined_row.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The largest share of the page's viewport a scrolling [BgeNestedRowsBox]
/// may take.
///
/// Named rather than written inline, as the page's own footer share is: it is
/// a proportion, not a spacing decision, so there is no token for it.
///
/// Flutter doesn't hand a drag from an inner scroll view to the one around
/// it, so a box that filled the view would leave a finger nowhere to move the
/// page from. Half leaves the page at least half (#1048).
const double _maxViewportFraction = 0.5;

/// How many rows a scrolling [BgeNestedRowsBox] shows whole. Half of the next
/// one shows under them, to say there are more (#1048).
const int _wholeRows = 3;

/// A long set of nested rows, in a box that scrolls inside the page (#1048).
///
/// For the rows shown under one row of a list, such as a base game's
/// expansions, once there are more than [inlineLimit] of them. Up to
/// [inlineLimit], a caller lays the rows out itself, in the list, with no
/// box.
///
/// **Its height.** Three and a half of its rows: the top of the fourth row
/// plus half that row's height, measured from the rows as they are laid out,
/// so the half row shows whatever the rows' heights. And never more than half
/// the height of the page's viewport, the nearest vertical scroll view around
/// the box, so the page keeps room to be dragged by: at 200% text, or in a
/// short window, that is less than one row. On a page of slivers, as a list
/// page is (`BgePage.slivers`), both hold on the box's first frame. A page
/// that is one `SingleChildScrollView` measures its child before it knows
/// its own height, so there the cap comes a frame late. Either way the cap
/// follows the page's viewport as it changes height, a frame behind it, on a
/// page with a `Scaffold`, as a `BgePage` is. The last [BgeTokens.spaceSm]
/// of that height is empty: the rows end part-way down one, so the box
/// leaves under them the gap an outlined row leaves under itself, and the
/// row after the box stands clear of the one cut short.
///
/// **Scrolling.** The rows scroll inside the box, under a scrollbar that
/// always shows and has room of its own at the rows' end, so its thumb covers
/// no row. The thumb is the second sign that there is more, after the half
/// row, so it is drawn in `outline`, which stands 3:1 clear of every surface
/// role in all four themes, where Material's own at rest is about 1.2:1 from
/// a light page. A mouse wheel moves the rows, and at either end of them it
/// moves the page instead, as does a trackpad on the web, which the browser
/// sends as a wheel. A touch drag, or a trackpad's pan in a native desktop
/// app, that starts in the box stays with the box, which is what the half of
/// the page is kept for.
///
/// **Keyboard.** Tab goes through the rows in their order, between the row
/// above the box and the row below it, and brings each into view: in the box
/// first, then on the page. A row taller than the box is shown from its top,
/// and with focus on it the platform's scroll keys, such as Page Down, move
/// the rows to show the rest. Focus that code gives a row while the keyboard
/// is in use, as a `BgeFocusHandoff` does, brings the row into view too:
/// only a traversal asks for that itself. A row that fits the box comes
/// whole into view. A row taller than the box is shown from its top, unless
/// it is being read part-way, with the box's top edge inside it: then one
/// that covers the box stays where it is, and one that ends inside the box
/// comes down until its end is the box's, so the box is all that row and
/// its reader keeps their place. Three kinds of focus move nothing. Focus a
/// press gives, which would scroll the rows under the pointer. Focus code
/// gives while the last input was a pointer's, which is drawn nowhere. And
/// the focus the framework gives back as the window or the browser's tab
/// comes back, which is where it was. The rows are the box's only stops, so
/// for rows that take no focus a caller sets [focusable], and the box is a
/// stop itself, whose keys move the rows.
///
/// **Screen readers.** The box is a group named [semanticLabel]. Its rows
/// count among themselves, so a row reads as "2 of 6" within the box, and
/// the page's own count is left alone: there the box is one item. Every row
/// stays in the tree, so moving on to one that is out of view scrolls to it.
///
/// **Rows.** A row that carries a key keeps its state, focus included, as
/// rows above it leave and arrive (#549). The key stays the row's own: the
/// box matches on a key made from it. The rows' page storage is the box's
/// own, not the page's: what a row keeps there under a `PageStorageKey` is
/// lost when the box's state goes, as when the box scrolls out of the page's
/// cache or its rows go back to being laid out without it, and rows laid
/// out without the box keep theirs in the page's.
///
/// With [inlineLimit] rows or fewer the box is the rows and nothing else: no
/// cap, no scrolling and no room kept for a bar.
class BgeNestedRowsBox extends StatefulWidget {
  /// Creates a box of [rows].
  const BgeNestedRowsBox({
    required this.rows,
    required this.semanticLabel,
    this.controller,
    this.focusable = false,
    super.key,
  });

  /// The most rows a caller shows without this box. From one more, the rows
  /// go in the box.
  static const int inlineLimit = 4;

  /// The rows, in the order they are shown, each as wide as the box less the
  /// scrollbar's room.
  final List<Widget> rows;

  /// Names the group for a screen reader, such as "Wingspan expansions".
  final String semanticLabel;

  /// Controls the box's own scrolling. The box keeps one of its own when this
  /// is null.
  ///
  /// Either way the rows' offset is kept out of the page's storage, whatever
  /// the controller's `keepScrollOffset`: the box opens at its top.
  final ScrollController? controller;

  /// Whether the box itself takes focus, for rows that take none.
  ///
  /// The rows are otherwise the box's only stops. A set with no stop of its
  /// own, as the Collection list's rows are where nothing can be opened,
  /// would leave a keyboard nothing to scroll the box by, and the rows past
  /// its end out of reach (WCAG 2.1.1).
  ///
  /// Set, the box is one Tab stop, named by [semanticLabel]. It draws the
  /// app's focus ring round its rows on keyboard focus. While it has focus,
  /// Arrow Up and Arrow Down move the rows by [BgeTokens.spaceXxl], Page Up
  /// and Page Down by what shows less that step, so the row at the edge
  /// stays in sight, Space and Shift+Space as Page Down and Page Up do, and
  /// Home and End to the ends. They move at once, as a Tab's reveal does.
  /// With nothing left to show that way, a new press is the framework's
  /// again, as a wheel's event is the page's: Page Down scrolls the page. A
  /// held page key, or Space, carries on into the page, as it does from a
  /// scrolling box on a web page. A held arrow stops there, or the focus
  /// would run down the page after the rows, and so does a held Home or
  /// End, whose one jump is all it asks for.
  ///
  /// Leave it false, the default, for rows that take focus: Tab already goes
  /// through them, and the box would be one more stop ahead of the first.
  /// With [inlineLimit] rows or fewer there is nothing to scroll, and the
  /// box is no stop either way.
  ///
  /// **When the box stops being a stop while it has the focus**, because this
  /// goes false or the rows drop to [inlineLimit], the focus goes to the
  /// first row in view that takes focus, as the rows are once that frame is
  /// built, and to the first of its stops as the row reads. The first in
  /// view, not the first of all, so the rows stay where they were scrolled
  /// to, but for bringing that row into view as focus from code does: see
  /// the class's Keyboard section. With no such row the box does nothing:
  /// the focus falls where the framework puts it, and a caller that keeps
  /// focus through such a change hands it on itself, as a `BgeFocusHandoff`
  /// does. The box leaving the tree with the focus is the caller's to handle
  /// too.
  final bool focusable;

  @override
  State<BgeNestedRowsBox> createState() => _BgeNestedRowsBoxState();
}

class _BgeNestedRowsBoxState extends State<BgeNestedRowsBox> {
  final GlobalKey _viewportKey = GlobalKey();

  ScrollController? _ownController;

  /// The scroll view the box is in, whose viewport caps it. Null outside one.
  ScrollPosition? _page;

  /// Reports every scroll view under the page's `Scaffold`. Null outside one.
  ScrollNotificationObserverState? _scrollViews;

  /// The box's own stop. See [BgeNestedRowsBox.focusable].
  late final FocusNode _focusNode = FocusNode(
    debugLabel: 'BgeNestedRowsBox',
    onKeyEvent: _onKey,
  )..addListener(_onFocusNodeChanged);

  /// The ring's own `onFocusChange`, from its latest build.
  ValueChanged<bool>? _ringFocusChange;

  /// A page storage of the box's own, which nothing is kept in.
  ///
  /// A scroll view with no storage key of its own saves its offset under the
  /// nearest key above it, as the page's does. So under a tab's key the box
  /// would open at the page's offset, and leave its own for the page to open
  /// at. Under this one there is no key, so nothing is read or saved, for
  /// the box's own controller or a caller's. The rows are under it as well:
  /// what one of them keeps in page storage lives as long as the box.
  final PageStorageBucket _storage = PageStorageBucket();

  ScrollController get _controller =>
      widget.controller ?? (_ownController ??= ScrollController());

  /// Whether [box] is a Tab stop itself: only with something to scroll.
  static bool _isStop(BgeNestedRowsBox box) =>
      box.focusable && box.rows.length > BgeNestedRowsBox.inlineLimit;

  /// Where the primary focus was before its last move.
  FocusNode? _focusBefore;

  @override
  void initState() {
    super.initState();
    _focusBefore = FocusManager.instance.primaryFocus;
    FocusManager.instance.addListener(_onFocusMoved);
    // Read by [_onFocusMoved]. The flag watches only while it has holders.
    BgePointerPressed.attach();
  }

  @override
  void didUpdateWidget(BgeNestedRowsBox oldWidget) {
    super.didUpdateWidget(oldWidget);
    // See "When the box stops being a stop" on [BgeNestedRowsBox.focusable].
    // After this frame, when the rows that can take the focus are built:
    // they may be this build's. The stop gives the focus up as it is built,
    // and a request made then lands before that is carried out, so the
    // focus never rests anywhere between.
    if (_isStop(oldWidget) && !_isStop(widget) && _focusNode.hasPrimaryFocus) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) _firstStopInView()?.requestFocus();
      });
    }
  }

  /// The stop the focus goes to as the box stops being one: in the first row
  /// in view that has a stop, the first as that row reads. Null when no row
  /// in view has one.
  ///
  /// Rows are told by where they are, not by the order the box's node holds
  /// their stops in, which is the order they arrived: a row that came later,
  /// above the rest, is last there.
  FocusNode? _firstStopInView() {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is! _RenderNestedRowsViewport) return null;

    var firstTop = double.infinity;
    var inFirstRow = <FocusNode>[];
    for (final stop in _focusNode.traversalDescendants) {
      final held = stop.context?.findRenderObject();
      final top = held == null ? null : viewport.topOfRowInView(held);
      if (top == null || top > firstTop) continue;
      if (top < firstTop) {
        firstTop = top;
        inFirstRow = [];
      }
      inFirstRow.add(stop);
    }
    return _firstAsRead(inFirstRow);
  }

  /// The first of [stops], all in one row, as the framework reads a line:
  /// the highest stop and whatever stands level with it, and of those the
  /// one nearest the start. Not simply the highest: of two side by side, the
  /// taller one's top is the higher, wherever it stands.
  FocusNode? _firstAsRead(List<FocusNode> stops) {
    if (stops.isEmpty) return null;
    // Read without depending on it: this runs at the end of a frame, where
    // nothing can be built again for a change in it.
    final fromRight =
        context
            .getInheritedWidgetOfExactType<Directionality>()
            ?.textDirection ==
        TextDirection.rtl;
    final highest = stops.reduce(
      (a, b) => b.rect.top < a.rect.top ? b : a,
    );
    final line = highest.rect;
    var first = highest;
    for (final stop in stops) {
      final rect = stop.rect;
      final level = rect.top < line.bottom && rect.bottom > line.top;
      final nearerTheStart = fromRight
          ? rect.right > first.rect.right
          : rect.left < first.rect.left;
      if (level && nearerTheStart) first = stop;
    }
    return first;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _page = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
    _listenTo(ScrollNotificationObserver.maybeOf(context));
  }

  /// Hears of scroll views from [scrollViews], and from no other.
  void _listenTo(ScrollNotificationObserverState? scrollViews) {
    if (identical(scrollViews, _scrollViews)) return;
    _scrollViews?.removeListener(_onScrollViewChanged);
    _scrollViews = scrollViews?..addListener(_onScrollViewChanged);
  }

  /// Out of the tree, the box hears of no scroll view.
  ///
  /// A box that scrolls out of a lazy list's cache is taken out of the tree
  /// in the page's layout, and its state lives on until that frame ends. The
  /// same layout can start a scroll, which the `Scaffold` tells of at once,
  /// and by then the box's viewport is no element to ask anything of. A box
  /// put back in the tree in that frame, as one moved under a global key is,
  /// is told of its dependencies again, and listens again from there.
  @override
  void deactivate() {
    _listenTo(null);
    super.deactivate();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_onFocusMoved);
    BgePointerPressed.detach();
    _focusNode
      ..removeListener(_onFocusNodeChanged)
      ..dispose();
    _ownController?.dispose();
    super.dispose();
  }

  /// Shows the row that code has just given the focus, in the box and then
  /// on the page, while the keyboard is in use.
  ///
  /// Tab asks for that itself as it moves the focus. Nothing else does: a
  /// `requestFocus` from code, as a `BgeFocusHandoff` makes when a row
  /// changes form, would leave the focus on a row out of sight. After a Tab
  /// the row is in view already, and this moves nothing.
  ///
  /// Three kinds of focus are left alone:
  ///
  /// - **Focus given back after the window, the browser's tab or the view
  ///   lost it.** The framework parks the focus on its root scope meanwhile,
  ///   and asks for it again for the node that had it. That node is where
  ///   the user left it: showing it would bring the page back to the box
  ///   from wherever it had been scrolled to.
  /// - **Focus a press gave**, as a tap gives a row that takes focus as it
  ///   opens. Showing it would scroll the rows under the pointer.
  /// - **Focus code gave while the last input was a pointer's.** It is drawn
  ///   nowhere, as every ring has it, and the rows would move for nothing a
  ///   user can see.
  ///
  /// The last two are one test, the rings' own: the highlight mode is the
  /// keyboard's, and no mouse or trackpad has pressed since the last key.
  void _onFocusMoved() {
    final before = _focusBefore;
    final focus = _focusBefore = FocusManager.instance.primaryFocus;
    if (focus == null || !_holds(focus)) return;
    // Given back, as above. The root scope holds the focus only while the
    // app, or its view, is without it, and before anything has taken it.
    if (identical(before, FocusManager.instance.rootScope)) return;
    final keyboardInUse =
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional &&
        !BgePointerPressed.value;
    if (!keyboardInUse) return;
    // A scroll can't be made in the middle of a build or a layout.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _show(focus));
    } else {
      _show(focus);
    }
  }

  /// Whether [node] is inside the box. The box's own stop is not: it is
  /// round the rows, and the page shows it.
  bool _holds(FocusNode node) {
    for (var above = node.parent; above != null; above = above.parent) {
      if (identical(above, _focusNode)) return true;
    }
    return false;
  }

  /// Scrolls no further than it takes to show [focus], and not at all for
  /// one in view. A jump, as a Tab's reveal is.
  void _show(FocusNode focus) {
    if (!mounted || !focus.hasPrimaryFocus) return;
    final shown = focus.context?.findRenderObject();
    if (shown != null && shown.attached) shown.showOnScreen();
  }

  /// The ring is the box's own: it shows while the box itself has focus, and
  /// not while a row inside it has, which draws its own. A `Focus` reports
  /// focus anywhere inside it, so the node is asked instead.
  void _onFocusNodeChanged() =>
      _ringFocusChange?.call(_focusNode.hasPrimaryFocus);

  /// Moves the rows for the keys [BgeNestedRowsBox.focusable] names, while
  /// the box itself has focus.
  ///
  /// A key from a focused row inside comes here too, and is left alone: the
  /// arrows there are the framework's move to the next row. So is a chord:
  /// Alt and an arrow is the browser's Back, and Control and Meta chords are
  /// the platform's.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !node.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }

    // The box's own position, whoever's controller it is on.
    final viewport = _viewportKey.currentContext;
    if (viewport == null) return KeyEventResult.ignored;
    final rows = Scrollable.of(viewport).position;
    final step = BgeTokens.of(context).spaceXxl;
    // At least a step, where the box shows less than two.
    final view = math.max(step, rows.viewportDimension - step);
    final key = event.logicalKey;
    // The keys whose held repeats stop at the rows' ends: all but the page
    // keys.
    final stopsWhenHeld =
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.home ||
        key == LogicalKeyboardKey.end;
    final wanted = switch (key) {
      LogicalKeyboardKey.arrowDown => rows.pixels + step,
      LogicalKeyboardKey.arrowUp => rows.pixels - step,
      LogicalKeyboardKey.pageDown => rows.pixels + view,
      LogicalKeyboardKey.pageUp => rows.pixels - view,
      // A page, as a browser's Space is, and up with Shift.
      LogicalKeyboardKey.space =>
        keyboard.isShiftPressed ? rows.pixels - view : rows.pixels + view,
      LogicalKeyboardKey.home => rows.minScrollExtent,
      LogicalKeyboardKey.end => rows.maxScrollExtent,
      _ => null,
    };
    if (wanted == null) return KeyEventResult.ignored;

    final target = clampDouble(
      wanted,
      rows.minScrollExtent,
      rows.maxScrollExtent,
    );
    if (target == rows.pixels) {
      // Nothing left to show that way. A new press goes on to the framework,
      // which scrolls the page or moves the focus. A held arrow's repeats
      // stop here, or holding Arrow Down through the rows would send the
      // focus running down the page after them, and so do Home's and End's,
      // whose one jump is all a held key asks for. A held page key's go on,
      // as a page that ends carries on down the one around it: they scroll,
      // and leave the focus where it is.
      return event is KeyRepeatEvent && stopsWhenHeld
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    rows.jumpTo(target);
    return KeyEventResult.handled;
  }

  /// The box's scrollbar round [child], always shown.
  ///
  /// Its thumb is `outline` at rest and `onSurface` under a pointer or a
  /// drag, each 3:1 clear of every surface role in all four themes. It is
  /// held [BgeTokens.focusOutlineWidth] plus [BgeTokens.focusRingGap] in
  /// from the box's edges, clear of where the box's focus ring is drawn,
  /// and takes [BgeTokens.radiusSm] ends.
  ///
  /// Material hands an iOS scrollbar to Cupertino's, whose thumb takes no
  /// colour and stands 2.4:1 from a light page. There the bar is drawn
  /// directly, as thin as Material's is on Android and, like it, not for
  /// dragging: a finger scrolls the rows themselves.
  Widget _scrollbar(
    BuildContext context, {
    required ScrollController controller,
    required Widget child,
  }) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tokens = BgeTokens.of(context);
    final clearOfRing = tokens.focusOutlineWidth + tokens.focusRingGap;
    final radius = Radius.circular(tokens.radiusSm);

    if (theme.platform == TargetPlatform.iOS) {
      return RawScrollbar(
        controller: controller,
        thumbVisibility: true,
        interactive: false,
        thumbColor: scheme.outline,
        thickness: tokens.spaceXs,
        radius: radius,
        crossAxisMargin: clearOfRing,
        mainAxisMargin: clearOfRing,
        child: child,
      );
    }
    return ScrollbarTheme(
      data: ScrollbarTheme.of(context).copyWith(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) =>
              states.contains(WidgetState.hovered) ||
                  states.contains(WidgetState.dragged)
              ? scheme.onSurface
              : scheme.outline,
        ),
        radius: radius,
        crossAxisMargin: clearOfRing,
        mainAxisMargin: clearOfRing,
      ),
      child: Scrollbar(
        controller: controller,
        thumbVisibility: true,
        child: child,
      ),
    );
  }

  /// The page's viewport can change height with nothing laying this box out
  /// again: a shorter window, a keyboard, a footer arriving. The page's
  /// width, which is all the box is laid out by, is the same. The `Scaffold`
  /// hears of it once that frame is over, and of every scroll besides, so
  /// this only asks the viewport whether its cap still stands.
  void _onScrollViewChanged(ScrollNotification _) {
    final viewport = _viewportKey.currentContext?.findRenderObject();
    if (viewport is _RenderNestedRowsViewport) viewport.followPage();
  }

  /// A key for a row's place in the column, made from the row's own.
  ///
  /// The column matches its children by their keys, and a key one level in,
  /// on the row, is invisible to it (#549). Made from the row's key rather
  /// than being it, so a finder by the row's key finds the row alone, and a
  /// global key is used once.
  static Key? _slotKeyOf(Widget row) {
    final key = row.key;
    return key == null ? null : ValueKey<Key>(key);
  }

  @override
  Widget build(BuildContext context) {
    final rows = widget.rows;
    final controller = _controller;
    final tokens = BgeTokens.of(context);
    final scrolls = rows.length > BgeNestedRowsBox.inlineLimit;
    // The bar's own room, so its thumb covers no row.
    final barRoom = EdgeInsetsDirectional.only(
      end: scrolls ? tokens.spaceMd : 0,
    );
    // Under rows cut short only: a set shown whole ends with its last row's
    // own gap. See "Its height" on the widget.
    final gapBelow = scrolls ? tokens.spaceSm : 0.0;

    final stop = _isStop(widget);

    final rowsView = PageStorage(
      bucket: _storage,
      child: Scrollable(
        controller: controller,
        // A desktop platform gives every scroll view a bar of its own, which
        // would be a second one here. For this scroll view alone: one inside
        // a row keeps the page's behaviour, its bar with it.
        scrollBehavior: ScrollConfiguration.of(
          context,
        ).copyWith(scrollbars: false),
        semanticChildCount: rows.length,
        viewportBuilder: (context, offset) => _NestedRowsViewport(
          key: _viewportKey,
          offset: offset,
          page: _page,
          peekRow: scrolls ? _wholeRows : null,
          gapBelow: gapBelow,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, row) in rows.indexed)
                IndexedSemantics(
                  key: _slotKeyOf(row),
                  index: index,
                  child: Padding(padding: barRoom, child: row),
                ),
            ],
          ),
        ),
      ),
    );

    // The same tree with the box a stop or not, so the rows keep their
    // offset as it becomes one.
    return ListenableBuilder(
      listenable: _focusNode,
      // The stop's own node, as `Focus` would add it, but on the node that
      // carries the name: left to `Focus`, the two would be a named group
      // and an unnamed stop inside it.
      builder: (context, box) => Semantics(
        container: true,
        explicitChildNodes: true,
        label: widget.semanticLabel,
        focused: stop ? _focusNode.hasPrimaryFocus : null,
        // As `Focus` has it: withheld on iOS (flutter/flutter#150030).
        onFocus: !stop || defaultTargetPlatform == TargetPlatform.iOS
            ? null
            : _focusNode.requestFocus,
        child: box,
      ),
      // One traversal group, around the box and not its rows, so Tab orders
      // the rows among themselves and places them all by where the box is.
      // Flutter orders Tab stops by where they are on screen, and the rows
      // past the box's end sit, unseen, over the page's rows below it:
      // without the group Tab went from the third row here to the page's
      // next row and back.
      child: FocusTraversalGroup(
        child: Padding(
          padding: EdgeInsets.only(bottom: gapBelow),
          child: BgeFocusRing(
            borderRadius: BgeOutlinedRow.borderRadiusOf(context),
            builder: (context, onFocusChange) {
              _ringFocusChange = onFocusChange;
              // Round the scroll view, not inside it: Tab then brings the
              // box into view on the page and leaves its rows where they
              // are.
              return Focus(
                focusNode: _focusNode,
                canRequestFocus: stop,
                skipTraversal: !stop,
                includeSemantics: false,
                child: _scrollbar(
                  context,
                  controller: controller,
                  child: rowsView,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The box's viewport over its column of rows.
class _NestedRowsViewport extends SingleChildRenderObjectWidget {
  const _NestedRowsViewport({
    required this.offset,
    required this.page,
    required this.peekRow,
    required this.gapBelow,
    required Column super.child,
    super.key,
  });

  final ViewportOffset offset;

  /// See [_RenderNestedRowsViewport.page].
  final ScrollMetrics? page;

  /// See [_RenderNestedRowsViewport.peekRow].
  final int? peekRow;

  /// See [_RenderNestedRowsViewport.gapBelow].
  final double gapBelow;

  @override
  _RenderNestedRowsViewport createRenderObject(BuildContext context) =>
      _RenderNestedRowsViewport(
        offset: offset,
        page: page,
        peekRow: peekRow,
        gapBelow: gapBelow,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderNestedRowsViewport renderObject,
  ) {
    renderObject
      ..offset = offset
      ..page = page
      ..peekRow = peekRow
      ..gapBelow = gapBelow;
  }

  @override
  SingleChildRenderObjectElement createElement() =>
      _NestedRowsViewportElement(this);
}

/// Counts this viewport in the depth of a scroll notification from inside
/// it, as every viewport's element does.
class _NestedRowsViewportElement extends SingleChildRenderObjectElement
    with NotifiableElementMixin, ViewportElementMixin {
  _NestedRowsViewportElement(_NestedRowsViewport super.widget);
}

/// A viewport over one column, sized from where the column puts its rows.
///
/// `SingleChildScrollView`'s viewport, for a column scrolling down, with
/// three differences:
///
/// - **Its height** is the column's, or with a [peekRow] the smaller of that
///   row's middle and half of [page]'s viewport, less [gapBelow]. A render
///   object rather than a measure taken after the frame, so on a page of
///   slivers the box is that height on the frame it first appears in: a
///   viewport of slivers sets its height before it lays them out. One like
///   this, over a single child, sets it after, so inside one [page] has no
///   height to read on that first frame, and the cap waits for
///   [followPage].
/// - **Its semantics** are a list's: it asks for the two nodes a `ListView`
///   has, which is what gives the scrolling node the index of the first row
///   in view, beside the count.
/// - **A reveal** never scrolls past its target's top. See
///   [getOffsetToReveal].
///
/// Its intrinsic widths are the column's. It has no intrinsic heights and no
/// dry layout: its height comes from where the rows land, which only a
/// layout knows.
class _RenderNestedRowsViewport extends RenderBox
    with RenderObjectWithChildMixin<RenderFlex>
    implements RenderAbstractViewport {
  _RenderNestedRowsViewport({
    required this._offset,
    required this._page,
    required this._peekRow,
    required this._gapBelow,
  });

  /// The page's viewport height as the last layout read it. Null when there
  /// was none to read.
  double? _pageExtent;

  ViewportOffset get offset => _offset;
  ViewportOffset _offset;
  set offset(ViewportOffset value) {
    if (value == _offset) return;
    if (attached) _offset.removeListener(_hasScrolled);
    _offset = value;
    if (attached) _offset.addListener(_hasScrolled);
    markNeedsLayout();
  }

  /// The scroll view this one is in, or null outside one.
  ScrollMetrics? get page => _page;
  ScrollMetrics? _page;
  set page(ScrollMetrics? value) {
    if (identical(value, _page)) return;
    _page = value;
    markNeedsLayout();
  }

  /// The index of the row whose top half ends the box, with every row before
  /// it shown whole. Null shows every row, with no cap.
  int? get peekRow => _peekRow;
  int? _peekRow;
  set peekRow(int? value) {
    if (value == _peekRow) return;
    _peekRow = value;
    markNeedsLayout();
  }

  /// The room the box keeps empty under this viewport. The height a
  /// [peekRow] gives, and its cap, are the box's, gap included, so the gap
  /// comes off this viewport's.
  double get gapBelow => _gapBelow;
  double _gapBelow;
  set gapBelow(double value) {
    if (value == _gapBelow) return;
    _gapBelow = value;
    markNeedsLayout();
  }

  /// Lays the box out again if [page]'s viewport is no longer the height the
  /// last layout read.
  void followPage() {
    final page = _page;
    if (!attached || page == null || !page.hasViewportDimension) return;
    if (page.viewportDimension == _pageExtent) return;
    // A scroll made during a layout arrives in the middle of one, and
    // nothing else can be laid out again until that frame is over.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (attached) markNeedsLayout();
      });
    } else {
      markNeedsLayout();
    }
  }

  void _hasScrolled() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _offset.addListener(_hasScrolled);
  }

  @override
  void detach() {
    _offset.removeListener(_hasScrolled);
    super.detach();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    config.addTagForChildren(RenderViewport.useTwoPaneSemantics);
  }

  double get _maxScrollExtent {
    final child = this.child;
    return child == null ? 0 : math.max(0, child.size.height - size.height);
  }

  /// The top of [row] in the column that laid it out.
  static double _topOf(RenderBox row) =>
      (row.parentData! as FlexParentData).offset.dy;

  /// How far below this viewport's top the row holding [object] starts, as
  /// the rows are scrolled now: less than nothing for a row that starts
  /// above it. Null when that row is out of view, or [object] is in no row.
  double? topOfRowInView(RenderObject object) {
    final rows = child;
    RenderObject? row = object;
    while (row != null && !identical(row.parent, rows)) {
      row = row.parent;
    }
    if (row is! RenderBox) return null;
    final top = _topOf(row) - offset.pixels;
    return top < size.height && top + row.size.height > 0 ? top : null;
  }

  /// The middle of row [peekRow] in [rows], or null with no such row.
  ///
  /// Read from where the column put its rows: a row ends where the next one
  /// starts, or where the column does. Not from the row's size, which is its
  /// parent's to read during a layout, and not this viewport's.
  double? _peekExtent(RenderFlex rows) {
    final index = _peekRow;
    if (index == null) return null;
    var row = rows.firstChild;
    for (var i = 0; i < index && row != null; i++) {
      row = rows.childAfter(row);
    }
    if (row == null) return null;
    final next = rows.childAfter(row);
    final top = _topOf(row);
    final bottom = next == null ? rows.size.height : _topOf(next);
    return (top + bottom) / 2;
  }

  @override
  double computeMinIntrinsicWidth(double height) =>
      child?.getMinIntrinsicWidth(height) ?? 0;

  @override
  double computeMaxIntrinsicWidth(double height) =>
      child?.getMaxIntrinsicWidth(height) ?? 0;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    assert(
      debugCannotComputeDryLayout(
        reason:
            'The height of a box of nested rows comes from where its rows '
            'land, which only a layout knows.',
      ),
      'debugCannotComputeDryLayout reports its reason itself',
    );
    return Size.zero;
  }

  /// This viewport's height over [rows], which have just been laid out.
  double _heightFor(RenderFlex rows) {
    final peek = _peekExtent(rows);
    if (peek == null) return rows.size.height;
    final pageExtent = _pageExtent;
    final withGap = pageExtent == null
        ? peek
        : math.min(peek, pageExtent * _maxViewportFraction);
    return math.max(0, withGap - _gapBelow);
  }

  @override
  void performLayout() {
    final page = _page;
    _pageExtent = page != null && page.hasViewportDimension
        ? page.viewportDimension
        : null;

    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
    } else {
      child.layout(constraints.widthConstraints(), parentUsesSize: true);
      size = constraints.constrain(
        Size(child.size.width, _heightFor(child)),
      );
    }

    if (offset.hasPixels) {
      if (offset.pixels > _maxScrollExtent) {
        offset.correctBy(_maxScrollExtent - offset.pixels);
      } else if (offset.pixels < 0) {
        offset.correctBy(-offset.pixels);
      }
    }
    offset
      ..applyViewportDimension(size.height)
      ..applyContentDimensions(0, _maxScrollExtent);
  }

  Offset get _paintOffset => Offset(0, -offset.pixels);

  bool _clipsAt(Offset paintOffset) =>
      paintOffset.dy < 0 || paintOffset.dy + child!.size.height > size.height;

  final LayerHandle<ClipRectLayer> _clipRectLayer =
      LayerHandle<ClipRectLayer>();

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final paintOffset = _paintOffset;

    void paintRows(PaintingContext context, Offset offset) =>
        context.paintChild(child, offset + paintOffset);

    if (_clipsAt(paintOffset)) {
      _clipRectLayer.layer = context.pushClipRect(
        needsCompositing,
        offset,
        Offset.zero & size,
        paintRows,
        oldLayer: _clipRectLayer.layer,
      );
    } else {
      _clipRectLayer.layer = null;
      paintRows(context, offset);
    }
  }

  @override
  void dispose() {
    _clipRectLayer.layer = null;
    super.dispose();
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    final paintOffset = _paintOffset;
    transform.translateByDouble(paintOffset.dx, paintOffset.dy, 0, 1);
  }

  @override
  Rect? describeApproximatePaintClip(RenderObject? child) =>
      child != null && _clipsAt(_paintOffset) ? Offset.zero & size : null;

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null) return false;
    return result.addWithPaintOffset(
      offset: _paintOffset,
      position: position,
      hitTest: (result, transformed) =>
          child.hitTest(result, position: transformed),
    );
  }

  /// Where to scroll to for [target] to show at [alignment], but never past
  /// the target's top.
  ///
  /// A row taller than the box can't show whole, and at 200% text most are.
  /// Tab asks for the end of the row it moves down to, which would cut the
  /// row's title off above the box. So such a row shows from its top,
  /// whichever way focus came to it.
  @override
  RevealedOffset getOffsetToReveal(
    RenderObject target,
    double alignment, {
    Rect? rect,
    Axis? axis,
  }) {
    rect ??= target.paintBounds;
    if (target is! RenderBox) {
      return RevealedOffset(offset: offset.pixels, rect: rect);
    }

    final bounds = MatrixUtils.transformRect(
      target.getTransformTo(child),
      rect,
    );
    final targetOffset = math.min(
      bounds.top,
      bounds.top - (size.height - bounds.height) * alignment,
    );
    return RevealedOffset(
      offset: targetOffset,
      rect: bounds.shift(Offset(0, -targetOffset)),
    );
  }

  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    if (!offset.allowImplicitScrolling) {
      return super.showOnScreen(
        descendant: descendant,
        rect: rect,
        duration: duration,
        curve: curve,
      );
    }

    // Taller than the box, with the box's top edge somewhere inside it: it
    // is being read part-way. Showing it again, as when the focus is handed
    // back to it, would take it back to its top from wherever its reader had
    // got to. So one that covers the box, top edge to bottom, stays where it
    // is: it is in view as far as it can be. And one that ends inside the
    // box comes down until its end is the box's. A strip of it at the top
    // would leave the focused row, and its ring, all but out of sight; down
    // is the least move that fills the box with it, and its reader keeps
    // their place. A Tab that arrives on such a row still shows it from its
    // top: that asks through [getOffsetToReveal], not here.
    if (descendant is RenderBox) {
      final inView = MatrixUtils.transformRect(
        descendant.getTransformTo(this),
        rect ?? descendant.paintBounds,
      );
      if (inView.height > size.height &&
          inView.top <= precisionErrorTolerance &&
          inView.bottom > 0) {
        final short = size.height - inView.bottom;
        if (short > precisionErrorTolerance) {
          offset.moveTo(
            offset.pixels - short,
            duration: duration,
            curve: curve,
          );
        }
        return super.showOnScreen(
          rect: Offset.zero & size,
          duration: duration,
          curve: curve,
        );
      }
    }

    final shown = RenderViewportBase.showInViewport(
      descendant: descendant,
      viewport: this,
      offset: offset,
      rect: rect,
      duration: duration,
      curve: curve,
    );
    super.showOnScreen(rect: shown, duration: duration, curve: curve);
  }

  /// Every row, in view or not: a row out of view stays in the semantics
  /// tree, marked hidden, for a screen reader to move on to.
  @override
  Rect describeSemanticsClip(RenderObject child) {
    final remaining = _maxScrollExtent - offset.pixels;
    return Rect.fromLTRB(
      semanticBounds.left,
      semanticBounds.top - offset.pixels,
      semanticBounds.right,
      semanticBounds.bottom + remaining,
    );
  }
}
