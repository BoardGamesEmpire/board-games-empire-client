import 'package:flutter/widgets.dart';

import 'package:ui/src/focus/focus_is_free.dart';
import 'package:ui/src/focus/pointer_focus_flag.dart';

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
/// The control noted can go while the route covers the page, as a refresh
/// banner's retry does once a sync succeeds, and the pop then puts focus on
/// the control focused before that one. The user can't move focus on a
/// covered page, so focus where the pop put it is focus the user hasn't
/// moved, and the note is taken again as the pop begins, in the frame after
/// this route is current again (#813). Only then: while the control noted is
/// still on the page, the note stands, so focus the route's caller moves as
/// the route closes, as from the future the push returned, counts as moved.
/// Focus moved during a page route's exit still counts as moved too. The
/// control noted can also go during the exit, while it holds the focus the
/// pop gave it, and the framework then puts focus on the control focused
/// before it: the note follows that move, and only that one, so the
/// replacement still takes focus once the route has gone.
///
/// A page route has gone when this route's secondary animation is dismissed.
/// A pop-up, such as a picker, runs no secondary animation, so the scope also
/// acts once this route is current again with none running. Whichever comes
/// first takes the hand-off. Nothing happens if no item can take the game's
/// focus by then, and a later pop gives it nothing either.
///
/// A control can go from an item that stays, such as a cover's expansions
/// badge once the game's last expansion goes, and be the control the page
/// focused last too. Its item hears of it through
/// [BgeFocusHandoff.controlLeaving], and the pop gives the focus to the
/// control the caller names in its place, such as the cover, in the same way
/// (#813).
///
/// ## Which control
///
/// An item can hold more than one control, such as a cover and its
/// expansions badge (#711). Focus goes to the replacement's control in the
/// place, among its controls, of the one that had it, else to its first. An
/// item that folds the game away, or folds away the place it was in, takes
/// it on the control it names (below).
///
/// ## A game in two places
///
/// A game nested under two base games has an item under each. The
/// replacement in the same place, under the same base game, takes the focus.
/// If there is none, and the game has left that place, as when its base game
/// goes, the game's item that was built first takes it.
///
/// ## A game folded away
///
/// A game can leave its place for one where no item of it is built, inside
/// another item that folds it away, as a marked expansion moves into its
/// base game's folded strip once a sync brings the base game. That item
/// names the game in [BgeFocusHandoff.folded]. When the game has left its
/// place and has no item built anywhere, the first item that folds it takes
/// the focus, on [BgeFocusHandoff.foldedControl], the control that shows the
/// game again, such as the base game's expansions badge (#813). Nothing
/// unfolds, and the page doesn't move.
///
/// A place can fold away with the game still in it, as a base game's open
/// strip does when it folds, from the cover's custom action while a cover
/// in the strip holds focus. The item that folds it names it in
/// [BgeFocusHandoff.foldedPlace]. When a focused game's item leaves that
/// place while the item that names it is built and folds the game, that
/// item takes the focus on its [BgeFocusHandoff.foldedControl] in the same
/// way, before [BgeFocusHandoffScope.isShown] is asked: the place still
/// shows the game, folded. If that item isn't built, focus is left to the
/// framework, as for a scroll-out.
///
/// A game still shown in its place gets nothing from an item that folds it
/// elsewhere, as below: a standalone expansion's own cover that scrolled
/// out is still shown, though its base game's cover folds it too. Nor does
/// one scrolled out of a place that is open: the item that unfolds it folds
/// nothing, so a cover scrolled out of an open strip hands nothing on.
///
/// ## A scroll-out
///
/// A focused item scrolled out of a lazy list's cache leaves as a replaced
/// one does, and the two can't be told apart as it goes. They can once the
/// frame has built: a replacement in the item's place is built by then, and
/// an item that scrolled out isn't, though the list still shows its game in
/// that place. The scope asks [BgeFocusHandoffScope.isShown] which (#819).
///
/// A game still shown in its place gets no hand-off, and focus goes where
/// the framework puts it: on the control the page focused most recently
/// that is still built, even off screen, else on the page itself. The scope
/// scrolls nothing.
///
/// A sync can move a game past a lazy list's cache, in its place or to
/// another. Either way its item isn't built for focus to go to, and the
/// scope doesn't scroll the list to build it: focus is left to the
/// framework, both at once and after a pop (#813). Only a game whose place
/// has folded away, or that has left its place, hands focus on: to the
/// built item that folded the place, else to a copy built elsewhere, else
/// to a built item that folds it away.
///
/// Without [BgeFocusHandoffScope.isShown], the scope can't tell a scroll-out
/// from a replacement: a focused item scrolled out hands focus to a copy of
/// the same game built elsewhere, else to an item that folds it away, if
/// there is one.
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
  const BgeFocusHandoffScope({required this.child, this.isShown, super.key});

  /// The list or grid, a box or a sliver.
  final Widget child;

  /// Whether the list still shows a game at a place, its item built or not:
  /// whether the screen placed it there. It is given the `identity` and the
  /// `place` that the game's [BgeFocusHandoff] named.
  ///
  /// Asked once a game's item has left, and neither an item of the game in
  /// that place nor an item that folds that place away is built: in the
  /// frame after a focused item leaves, and as a pop's restore lands. True
  /// means the item scrolled out of a lazy list's cache, or was moved past
  /// it, and the framework places the focus. False means the game has left
  /// that place, and its item built elsewhere, else an item that folds it
  /// away, if any, takes the focus. The scope's doc, "A scroll-out", says
  /// why.
  ///
  /// A place inside another item, such as a base game's strip of expansion
  /// covers, can be open or folded, and the screen may not know which: the
  /// grid that unfolds a strip holds that. Such a screen counts the place's
  /// games as shown either way. The two answers differ only when the place
  /// folds while one of its items holds focus. A tap can't do that, as it
  /// focuses the control it folds from first, but a screen reader's custom
  /// action on another control can, such as a cover's "Hide expansions".
  /// The item that folded the place takes the focus then, before this is
  /// asked, if it is built and names the place as its
  /// [BgeFocusHandoff.foldedPlace] (#813). If it isn't built, the answer
  /// leaves focus to the framework, which puts it on the control the page
  /// focused most recently that is still built (#819).
  ///
  /// Without it, every answer is taken as false, as before #819: a focused
  /// item scrolled out hands focus to a copy of the game built elsewhere,
  /// else to an item that folds it away.
  final bool Function(Object identity, Object? place)? isShown;

  @override
  State<BgeFocusHandoffScope> createState() => _BgeFocusHandoffScopeState();
}

/// A game whose item a covered route will give focus back to has left, or a
/// control of it has.
class _Pending {
  _Pending(
    this.identity,
    this.place, {
    required this.page,
    required this.control,
    required bool pointerFocus,
  }) : pointerFocus = PointerFocusFlag(value: pointerFocus);

  final Object identity;
  final Object? place;

  /// The page whose focus history the pop gives focus back from.
  final FocusScopeNode page;

  /// Which of the item's controls the pop would have given focus to.
  final int control;

  /// The item's focus a click gave, which a key press on the route above
  /// still ends while the hand-off waits.
  final PointerFocusFlag pointerFocus;

  /// Where the pop will put focus instead: the control focused before, or
  /// null for the page itself. Noted once the item's nodes have left the
  /// page's focus history, and again as the pop begins (#813).
  FocusNode? restoredTo;
}

/// What takes a game's focus: an item, and which of its controls.
typedef _Target = ({_BgeFocusHandoffState item, int control});

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

  /// The primary focus as last seen while a pop's exit runs, or null when
  /// the scope isn't watching it (_watchExit).
  FocusNode? _lastFocus;

  bool _watchingExit = false;

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
    if (!uncovered) return;
    // The pop has begun, and has given focus back to the control the page
    // focused last. The control noted may have gone meanwhile, as a refresh
    // banner's retry does once a sync succeeds, and focus is then on the
    // one before it: that is still focus the user hasn't moved (#813). A
    // control noted that is still there stays noted, so focus the caller
    // moves as the route closes isn't taken for the pop's.
    final pending = _pending;
    final noted = pending?.restoredTo;
    // A node keeps its ancestors cached once it leaves, so the page is
    // asked.
    if (pending != null &&
        noted != null &&
        !pending.page.descendants.contains(noted)) {
      _noteAfterFrame(pending);
    }
    if (pending != null) _watchExit();
    // A pop-up has gone, as no page route's exit is running. Its restore
    // runs after the note, in the same frame.
    if (above?.isDismissed ?? true) _restoreAfterFrame();
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
    _stopWatchingExit();
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
      // Whether the item scrolled out or was replaced shows only once the
      // frame has built, so the lookup decides (_targetOf).
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
    _keep(item, page, control: item._controlHolding(remembered));
  }

  /// Called as [leaving], a control inside [item], goes while [item] stays,
  /// with [to] the control that stands in its place
  /// ([BgeFocusHandoff.controlLeaving]).
  void _controlLeft(
    _BgeFocusHandoffState item, {
    required FocusNode leaving,
    required FocusNode to,
  }) {
    if (!_active || _current) return;
    final page = leaving.enclosingScope;
    final remembered = page?.focusedChild;
    if (page == null || remembered == null) return;
    if (remembered != leaving && !remembered.ancestors.contains(leaving)) {
      return;
    }
    _keep(item, page, control: item._controlHolding(to, without: leaving));
  }

  /// Keeps [item]'s game for the pop to give focus back to, at [control]
  /// among the item's controls, and notes where the pop will put focus
  /// instead once the frame has built.
  void _keep(
    _BgeFocusHandoffState item,
    FocusScopeNode page, {
    required int control,
  }) {
    // With a game already kept, this item is one the page focused before
    // that game's: the kept game stays the one to come back to, and only
    // where the pop will put focus changes.
    final pending = _pending ??= _Pending(
      item.widget.identity,
      item.widget.place,
      page: page,
      control: control,
      pointerFocus: item._pointerFocus.value,
    );
    _noteAfterFrame(pending);
  }

  /// Notes where the pop will put focus instead of on [pending]'s game,
  /// once the frame has built: the control its page focused last, or null
  /// for the page itself.
  void _noteAfterFrame(_Pending pending) {
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted) return;
        pending.restoredTo = pending.page.focusedChild;
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

  /// Watches focus from the pop's start until its restore, so that a noted
  /// control that goes while it holds focus, as a refresh banner's retry
  /// does once a sync succeeds during a page's exit, is noted again where
  /// the framework puts its focus (#813). Focus the user moves off the
  /// noted control, before or after it goes, is theirs, and stays.
  void _watchExit() {
    if (_watchingExit) return;
    _watchingExit = true;
    _lastFocus = FocusManager.instance.primaryFocus;
    FocusManager.instance.addListener(_onFocusMoved);
  }

  void _stopWatchingExit() {
    if (!_watchingExit) return;
    _watchingExit = false;
    _lastFocus = null;
    FocusManager.instance.removeListener(_onFocusMoved);
  }

  void _onFocusMoved() {
    final last = _lastFocus;
    _lastFocus = FocusManager.instance.primaryFocus;
    final pending = _pending;
    if (pending == null || last == null || last != pending.restoredTo) {
      return;
    }
    // Focus left the noted control. Still in the page, the user moved it;
    // gone, the framework did, onto the control the page focused before.
    // A node keeps its ancestors cached once it leaves, so the page is
    // asked.
    if (pending.page.descendants.contains(last)) return;
    pending.restoredTo = pending.page.focusedChild;
  }

  /// Hands [pending] its focus if it can, and is done with it either way.
  void _restore(_Pending pending) {
    _stopWatchingExit();
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

  /// Gives the game's focus to the item [_targetOf] finds, with the state of
  /// focus a click gave.
  ///
  /// When that state is new to the item, its controls were built for the
  /// other one. An ink fixes its focus tint's strength from the colour it
  /// was last built with when focus arrives, and a focus request lands
  /// before the rebuild the state asks for. So focus waits a frame on the
  /// page, where the framework puts nothing else, and goes on to the item
  /// once its controls are built for the state. Focus the user has moved
  /// meanwhile stays where it is.
  ///
  /// The item is looked up again after the wait, as the game can change
  /// form again in that frame. The state goes on as the waiting item
  /// holds it, which a key press in that frame ends. A replacement built
  /// meanwhile is new to it too, and focus waits for that one in turn.
  void _focusItemOf(
    Object identity,
    Object? place, {
    required int control,
    required bool pointerFocus,
  }) {
    final target = _targetOf(identity, place, control: control);
    if (target == null) return;
    final item = target.item;
    final node = item._control(target.control);
    if (node == null) return;
    if (item._pointerFocus.value == pointerFocus) {
      node.requestFocus();
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

  /// What takes the focus of the game [identity]'s item in [place], once
  /// that item has left: an item, and which of its controls, or null for
  /// nothing. [control] is the place, among the left item's controls, of
  /// the one that had the focus. In turn:
  ///
  /// 1. The game's item in [place], if one is built: a replacement, at
  ///    [control].
  /// 2. Else a built item that folds the game away and names [place] as its
  ///    [BgeFocusHandoff.foldedPlace]: [place] itself has folded away, as a
  ///    base game's strip does, and that item takes the focus at its
  ///    [BgeFocusHandoff.foldedControl] (#813). An item that unfolds
  ///    [place] folds nothing, so an item scrolled out of an open place
  ///    finds none.
  /// 3. Nothing, if the list still shows the game in [place]
  ///    ([BgeFocusHandoffScope.isShown]): its item there scrolled out of a
  ///    lazy list's cache, or was moved past it, and the framework places
  ///    focus. Neither of the steps below is taken.
  /// 4. Else the first of the game's items built elsewhere, at [control],
  ///    as the game has left [place] (#711).
  /// 5. Else the first item that folds the game away, at its
  ///    [BgeFocusHandoff.foldedControl] (#813).
  _Target? _targetOf(Object identity, Object? place, {required int control}) {
    final items = _items.where((item) => item.widget.identity == identity);
    final replacement = items
        .where((item) => item.widget.place == place)
        .firstOrNull;
    if (replacement != null) return (item: replacement, control: control);
    final holders = _items.where(
      (item) => item.widget.folded.contains(identity),
    );
    final foldedHere = holders
        .where((item) => place != null && item.widget.foldedPlace == place)
        .firstOrNull;
    if (foldedHere != null) {
      return (item: foldedHere, control: foldedHere.widget.foldedControl);
    }
    if (widget.isShown?.call(identity, place) ?? false) return null;
    final copy = items.firstOrNull;
    if (copy != null) return (item: copy, control: control);
    final holder = holders.firstOrNull;
    if (holder == null) return null;
    return (item: holder, control: holder.widget.foldedControl);
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
///
/// An item can fold other games away, as a base game's cover does with its
/// expansions while its strip is folded. It names them in [folded], so that
/// a focused game that moves in there gives its focus to the control that
/// shows it again, [foldedControl] (#813), and the place they take when it
/// unfolds them in [foldedPlace], so that a focused game whose place folds
/// does too. A control that goes while its item stays, such as a cover's
/// expansions badge, says so with [controlLeaving], so that a pop gives the
/// focus it would have given that control to another in the item.
class BgeFocusHandoff extends StatefulWidget {
  /// Wraps [child], an item of the game [identity] at [place].
  const BgeFocusHandoff({
    required this.identity,
    required this.child,
    this.place,
    this.folded = const <Object>{},
    this.foldedPlace,
    this.foldedControl = 0,
    super.key,
  });

  /// The game the item stands for, such as its id.
  final Object identity;

  /// Where the item is, such as the base game it is nested under, or null at
  /// top level.
  final Object? place;

  /// The games this item folds away, which have no item of their own in
  /// the list, such as a base game's expansions while its strip is folded.
  /// Empty for none.
  ///
  /// A focused game that leaves its place for one inside this item, with no
  /// item of it built anywhere, gives its focus to [foldedControl], at once
  /// or as a pop's restore lands. The scope's doc, "A game folded away",
  /// says when.
  final Set<Object> folded;

  /// The place the games in [folded] take while this item unfolds them:
  /// the [place] their items name there, such as the base game's strip.
  /// Null, the default, for none; a folded place is never top level.
  ///
  /// When a focused game's item leaves that place while this item is built
  /// and folds the game, the place has folded away, not scrolled out: this
  /// item takes the focus on [foldedControl], at once or as a pop's restore
  /// lands, before [BgeFocusHandoffScope.isShown] is asked. While the item
  /// unfolds the place, [folded] is empty, so an item scrolled out of the
  /// open place hands nothing on. The scope's doc, "A game folded away",
  /// says when.
  final Object? foldedPlace;

  /// Which of the item's controls shows the games in [folded], counted from
  /// 0 in the order of its widgets: `BgeCoverTile.expansionsControl` for a
  /// cover tile's expansions badge, which comes after the cover. The first,
  /// if the item has fewer.
  final int foldedControl;

  /// The item.
  final Widget child;

  /// Tells the item around [context] that [leaving], one of its controls,
  /// is going while the item stays, and that [to], another of its
  /// controls, stands in its place (#813). Called as the widget that holds
  /// [leaving] updates, before [leaving] has gone, as a cover tile does when
  /// its expansions badge goes.
  ///
  /// While a route covers the page, [leaving] holds no focus, but the
  /// page's focus history can remember it, and the pop would then give
  /// focus to the control focused before it. If [leaving], or a node inside
  /// it, is the one the history holds last, the scope keeps the game as it
  /// does for an item that leaves: the pop gives focus to [to], or to the
  /// control in its place if the game has changed form meanwhile, once the
  /// route above has gone, unless the user has moved focus since.
  ///
  /// It does nothing outside a [BgeFocusHandoffScope], or while the scope's
  /// route is current: a control that holds focus as it goes is the
  /// caller's to hand on at once.
  static void controlLeaving(
    BuildContext context, {
    required FocusNode leaving,
    required FocusNode to,
  }) {
    final item = context.findAncestorStateOfType<_BgeFocusHandoffState>();
    item?._scope?._controlLeft(item, leaving: leaving, to: to);
  }

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
  /// expansions badge is (#711).
  ///
  /// Read from the elements as they stand, which are the previous frame's
  /// whenever it is read mid-frame: as the item leaves, and from
  /// [BgeFocusHandoff.controlLeaving], which a control calls from its
  /// `didUpdateWidget`, inside the item's build, before the elements below
  /// it are built again. A hand-off reads it once the frame has built.
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
  /// Counted without [without], a control on its way out.
  int _controlHolding(FocusNode? node, {FocusNode? without}) {
    if (node == null) return 0;
    final index = _controls
        .where((control) => control != without)
        .toList()
        .indexWhere(
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
