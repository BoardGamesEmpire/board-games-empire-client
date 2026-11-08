import 'package:flutter/widgets.dart';

import 'focus_is_free.dart';
import 'pointer_focus_flag.dart';

/// Where the items of one list or grid hand a game's keyboard focus to each
/// other as the game changes form (#769, #711). Each item is wrapped in a
/// [BgeFocusHandoff] that names its game.
///
/// A game can be drawn in more than one form. In Collection, a game owned
/// once is an entry's row and a game owned more than once is a stack; an
/// expansion is a row at top level or one under its base game. Each form is
/// a different widget under a different key. When a game changes form, its
/// item is replaced, focus node and all, and the replacement gets the focus
/// in two cases.
///
/// ## The focused item leaves
///
/// The focus goes to the replacement at the end of the frame that replaced
/// the item, or a frame later for focus a click gave, as below. It can't go
/// as the item leaves: a replacement in the same place in a list is built
/// only after the old item has gone. Left alone, the framework would hand
/// focus back to whatever the page focused before, such as another row. The
/// hand-off takes it first.
///
/// ## The item a covered route will give focus back to leaves
///
/// A pop gives focus back to the control the page focused last. With that
/// item gone, focus would land on the control focused before it, or on the
/// page. So the scope keeps the game, and notes where the pop will put focus
/// instead. Once the route above has gone, the replacement takes focus from
/// there. Focus the user has moved since stays where it is.
///
/// A page route has gone when this route's secondary animation is dismissed.
/// A pop-up, such as a picker, runs no secondary animation, so the scope also
/// acts once this route is current again with none running. Whichever comes
/// first takes the hand-off. Nothing happens if the game has no item by then,
/// and a later pop gives it nothing either.
///
/// ## Which control
///
/// An item can hold more than one control, such as a cover and its
/// expansions badge (#711). Focus goes to the replacement's control in the
/// place, among its controls, of the one that had it, else to its first.
///
/// ## A game in two places
///
/// A game nested under two base games has an item under each. The
/// replacement in the same place, under the same base game, takes the focus.
/// If there is none, the game's item that was built first takes it.
///
/// A focused item scrolled out of a lazy list's cache counts as leaving too.
/// Focus goes to a copy of the same game that is still built, if there is
/// one, and is left to the framework if not.
///
/// ## Focus a click gave stays undrawn
///
/// Focus a mouse or a trackpad gave isn't drawn, neither its ring nor its
/// ink's tint (`BgePointerFocus`). That state is the item's, and goes to the
/// replacement with the focus, so the new form draws neither for a user who
/// never touched the keyboard. While a hand-off waits on a pop, a key press
/// on the route above still ends it.
///
/// A replacement built for the other state gets the focus a frame late. An
/// ink fixes its tint's strength from the colour it was last built with when
/// focus arrives, so focus waits on the page while the replacement rebuilds.
/// If the game changes form again meanwhile, focus waits for the newest
/// replacement in turn. Focus the keyboard gave, onto a replacement built for
/// it, moves at once.
///
/// The scope builds no render object of its own, so it can stand among
/// slivers as well as boxes.
class BgeFocusHandoffScope extends StatefulWidget {
  /// Creates the scope for the [BgeFocusHandoff]s in [child].
  const BgeFocusHandoffScope({required this.child, super.key});

  /// The list or grid, a box or a sliver.
  final Widget child;

  @override
  State<BgeFocusHandoffScope> createState() => _BgeFocusHandoffScopeState();
}

/// A game whose item a covered route will give focus back to has left.
class _Pending {
  _Pending(
    this.identity,
    this.place, {
    required this.control,
    required bool pointerFocus,
  }) : pointerFocus = PointerFocusFlag(pointerFocus);

  final Object identity;
  final Object? place;

  /// Which of the item's controls the pop would have given focus to.
  final int control;

  /// The item's focus a click gave, which a key press on the route above
  /// still ends while the hand-off waits.
  final PointerFocusFlag pointerFocus;

  /// Where the pop will put focus instead, once the item's nodes have left
  /// the page's focus history: the control focused before it, or null for
  /// the page itself.
  FocusNode? restoredTo;
}

class _BgeFocusHandoffScopeState extends State<BgeFocusHandoffScope> {
  /// The items built, in the order they were.
  final _items = <_BgeFocusHandoffState>[];

  _Pending? _pending;

  /// This route's secondary animation, which runs as a page route above it
  /// comes in and goes.
  Animation<double>? _above;

  /// Whether this route is the one on top.
  bool _current = true;

  /// False while the scope itself is going, as its items go with it.
  bool _active = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final above = ModalRoute.of(context)?.secondaryAnimation;
    if (!identical(above, _above)) {
      _above?.removeStatusListener(_onAboveChanged);
      _above = above?..addStatusListener(_onAboveChanged);
    }
    final current = ModalRoute.isCurrentOf(context) ?? true;
    final uncovered = current && !_current;
    _current = current;
    // A pop-up has gone, as no page route's exit is running.
    if (uncovered && (above?.isDismissed ?? true)) _restoreAfterFrame();
  }

  @override
  void activate() {
    super.activate();
    _active = true;
  }

  @override
  void deactivate() {
    _active = false;
    super.deactivate();
  }

  @override
  void dispose() {
    _above?.removeStatusListener(_onAboveChanged);
    _pending?.pointerFocus.dispose();
    super.dispose();
  }

  /// Called as [item] leaves, before its focus nodes do.
  void _left(_BgeFocusHandoffState item) {
    if (!_active) return;
    final identity = item.widget.identity;
    final place = item.widget.place;
    final node = item._node;
    final pointerFocus = item._pointerFocus.value;
    if (node.hasFocus) {
      _handOffAfterFrame(
        identity,
        place,
        control: item._controlHolding(FocusManager.instance.primaryFocus),
        pointerFocus: pointerFocus,
      );
      return;
    }
    if (_current) return;
    final page = node.enclosingScope;
    final remembered = page?.focusedChild;
    if (page == null || remembered == null) return;
    if (!remembered.ancestors.contains(node)) return;
    // With a game already kept, this item is one the page focused before
    // that game's: the kept game stays the one to come back to, and only
    // where the pop will put focus changes.
    final pending = _pending ??= _Pending(
      identity,
      place,
      control: item._controlHolding(remembered),
      pointerFocus: pointerFocus,
    );
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted) return;
        pending.restoredTo = page.focusedChild;
      })
      // A post-frame callback doesn't ask for a frame.
      ..ensureVisualUpdate();
  }

  void _handOffAfterFrame(
    Object identity,
    Object? place, {
    required int control,
    required bool pointerFocus,
  }) {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted || !_active) return;
        // On nothing, as the item went in this frame and the framework has
        // yet to hand focus on.
        if (!focusIsFree(context)) return;
        _focusItemOf(
          identity,
          place,
          control: control,
          pointerFocus: pointerFocus,
        );
      })
      ..ensureVisualUpdate();
  }

  void _onAboveChanged(AnimationStatus status) {
    if (!status.isDismissed) return;
    final pending = _pending;
    _pending = null;
    if (pending != null) _restore(pending);
  }

  /// Takes the kept game now, so the page route's trigger finds nothing, and
  /// hands it focus once the frame that showed this route again has built.
  void _restoreAfterFrame() {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => _restore(pending))
      ..ensureVisualUpdate();
  }

  /// Hands [pending] its focus if it can, and is done with it either way.
  void _restore(_Pending pending) {
    final pointerFocus = pending.pointerFocus.value;
    pending.pointerFocus.dispose();
    if (!mounted || !_active) return;
    if (!focusIsFree(context, untouched: pending.restoredTo)) return;
    _focusItemOf(
      pending.identity,
      pending.place,
      control: pending.control,
      pointerFocus: pointerFocus,
    );
  }

  /// Gives focus to the game's item, with the state of focus a click gave.
  ///
  /// When that state is new to the item, its controls were built for the
  /// other one. An ink fixes its focus tint's strength from the colour it
  /// was last built with when focus arrives, and a focus request lands
  /// before the rebuild the state asks for. So focus waits a frame on the
  /// page, where the framework puts nothing else, and goes on to the item
  /// once its controls are built for the state. Focus the user has moved
  /// meanwhile stays where it is.
  ///
  /// The game's item is looked up again after the wait, as the game can
  /// change form again in that frame. The state goes on as the waiting item
  /// holds it, which a key press in that frame ends. A replacement built
  /// meanwhile is new to it too, and focus waits for that one in turn.
  void _focusItemOf(
    Object identity,
    Object? place, {
    required int control,
    required bool pointerFocus,
  }) {
    final item = _itemOf(identity, place);
    final target = item?._control(control);
    if (item == null || target == null) return;
    if (item._pointerFocus.value == pointerFocus) {
      target.requestFocus();
      return;
    }
    item._pointerFocus.value = pointerFocus;
    final page = FocusScope.of(context, createDependency: false)
      ..requestScopeFocus();
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted || !_active) return;
        if (FocusManager.instance.primaryFocus != page) return;
        _focusItemOf(
          identity,
          place,
          control: control,
          // Read even if the item has gone since: its last value stands.
          pointerFocus: item._pointerFocus.value,
        );
      })
      ..ensureVisualUpdate();
  }

  /// The game's item in [place], else the first of its items built.
  _BgeFocusHandoffState? _itemOf(Object identity, Object? place) {
    final items = _items.where((item) => item.widget.identity == identity);
    return items.where((item) => item.widget.place == place).firstOrNull ??
        items.firstOrNull;
  }

  @override
  Widget build(BuildContext context) =>
      _BgeFocusHandoffMarker(scope: this, child: widget.child);
}

class _BgeFocusHandoffMarker extends InheritedWidget {
  const _BgeFocusHandoffMarker({required this.scope, required super.child});

  final _BgeFocusHandoffScopeState scope;

  @override
  bool updateShouldNotify(_BgeFocusHandoffMarker oldWidget) =>
      !identical(scope, oldWidget.scope);
}

/// One item of a game in a [BgeFocusHandoffScope]: a row or a tile, in
/// whichever form the game takes there (#769, #711).
///
/// [identity] names the game, and [place] where in the list this item of it
/// is, such as the base game it is nested under, or null at top level. Two
/// items of one game in different forms share [identity], so the focus that
/// one held goes to the other when the first is replaced. The scope's doc
/// says when.
///
/// The item's controls are the ones inside [child] that keyboard navigation
/// stops at, in the order of its widgets. The focus goes to the control in
/// the place of the one that had it, such as a cover's expansions badge,
/// else to the first. The wrapper takes no focus itself, adds no stop and
/// no semantics node, and builds no render object, so it can sit between a
/// sliver and its box children.
class BgeFocusHandoff extends StatefulWidget {
  /// Wraps [child], an item of the game [identity] at [place].
  const BgeFocusHandoff({
    required this.identity,
    required this.child,
    this.place,
    super.key,
  });

  /// The game the item stands for, such as its id.
  final Object identity;

  /// Where the item is, such as the base game it is nested under, or null at
  /// top level.
  final Object? place;

  /// The item.
  final Widget child;

  @override
  State<BgeFocusHandoff> createState() => _BgeFocusHandoffState();
}

class _BgeFocusHandoffState extends State<BgeFocusHandoff> {
  final _node = FocusNode(
    debugLabel: 'BgeFocusHandoff',
    canRequestFocus: false,
    skipTraversal: true,
  );

  /// The item's focus a click gave, shared by the controls in it.
  final _pointerFocus = PointerFocusFlag();

  _BgeFocusHandoffScopeState? _scope;

  @override
  void initState() {
    super.initState();
    _register();
  }

  @override
  void activate() {
    super.activate();
    _register();
  }

  @override
  void deactivate() {
    final scope = _scope;
    _scope = null;
    if (scope != null) {
      scope._items.remove(this);
      scope._left(this);
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _node.dispose();
    _pointerFocus.dispose();
    super.dispose();
  }

  void _register() {
    _scope = context
        .getInheritedWidgetOfExactType<_BgeFocusHandoffMarker>()
        ?.scope;
    _scope?._items.add(this);
  }

  /// The item's controls: the nodes inside it that keyboard navigation stops
  /// at, the outermost, in the order of the item's widgets.
  ///
  /// By the widgets, not the order the nodes were attached in. A control
  /// built at layout, as a cover tile's cover is under its `LayoutBuilder`,
  /// is attached after one built beside it at once, as the cover's
  /// expansions badge is (#711). Not read while the item builds.
  List<FocusNode> get _controls {
    final byElement = <BuildContext, FocusNode>{
      for (final node in _node.traversalDescendants) ?node.context: node,
    };
    final controls = <FocusNode>[];
    void visit(Element element) {
      final node = byElement[element];
      if (node != null) {
        controls.add(node);
      } else {
        element.visitChildren(visit);
      }
    }

    (context as Element).visitChildren(visit);
    return controls;
  }

  /// Which of [_controls] holds [node], or is it: 0, the first, if none.
  int _controlHolding(FocusNode? node) {
    if (node == null) return 0;
    final index = _controls.indexWhere(
      (control) => control == node || node.ancestors.contains(control),
    );
    return index < 0 ? 0 : index;
  }

  /// The control at [index] among [_controls], else the first, if any.
  FocusNode? _control(int index) {
    final controls = _controls;
    return index < controls.length ? controls[index] : controls.firstOrNull;
  }

  @override
  Widget build(BuildContext context) => Focus(
    focusNode: _node,
    canRequestFocus: false,
    skipTraversal: true,
    includeSemantics: false,
    child: PointerFocusFlagScope(flag: _pointerFocus, child: widget.child),
  );
}
