import 'dart:collection' show UnmodifiableSetView;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:ui/src/focus/bge_focus_handoff.dart';
import 'package:ui/src/images/bge_cover_expansions.dart';
import 'package:ui/src/images/bge_thumbnail.dart';
import 'package:ui/src/layout/bge_nested_rows_box.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A list row whose tile may carry a base game's [BgeRowExpansionsControl]
/// at its end, the way a screen lays one out (#1048).
///
/// Goes inside the row's `BgeOutlinedRow`, in place of the tile's own
/// `MergeSemantics`, which is this widget's. [builder] builds the tile, a
/// `BgeRowFocusRing` that takes the focus node it is given. With
/// [expansions], the tile's node offers the Show/Hide expansions custom
/// action ([bgeRowExpansionsAction]), and the control sits beside the tile,
/// after it; without, the row is the tile alone.
///
/// ```dart
/// BgeOutlinedRow(
///   child: BgeExpansionsRow(
///     expansions: expansions,
///     builder: (context, focusNode) => BgeRowFocusRing(
///       focusNode: focusNode,
///       builder: (_, row) => ListTile(...),
///     ),
///   ),
/// )
/// ```
///
/// The tile keeps its element, its focus and its node as the control comes
/// and goes, as a base game's expansions arrive on a later page or a sync
/// takes them. A control that goes while it holds focus gives it to the
/// tile, so the user keeps their place on the game, not on the page. One
/// that goes while a route covers the page, and the page's focus history
/// remembers it, has the pop give focus to the tile, in a game's
/// [BgeFocusHandoff] (#813), as a cover's badge does (#711).
///
/// A tile that takes no focus, as an inert row's, can't take it. A control
/// that goes while it holds focus then stays for the rest of the frame,
/// and once the page is laid out, hands it on: to the tile, if the same
/// update gave the row something to open, else as Tab would, to the next
/// stop after the row, else to the one before it, brought into view, never
/// to the page. It goes in the next frame. Under a covering route
/// the pop gives focus to the item's first control, if it has one left,
/// and otherwise to the control the page focused before this one, or with
/// none, to the page.
///
/// At large text, from [BgeThumbnail.titleHeightTextScale], the control
/// stands [BgeTokens.spaceMd] down the row, level with the title's first
/// line, as a list row's thumbnail does ([BgeThumbnail.titleAlignmentOf]),
/// rather than in the middle of a row that wraps tall. Below that it is in
/// the middle.
class BgeExpansionsRow extends StatefulWidget {
  /// Creates a row of [builder]'s tile, with the control for [expansions].
  const BgeExpansionsRow({
    required this.builder,
    this.expansions,
    super.key,
  });

  /// The base game's expansions, which the control counts and toggles. Null
  /// for a row with none, which has no control.
  final BgeCoverExpansions? expansions;

  /// Builds the row's tile, which takes `focusNode` as its focus: the node
  /// the control gives focus to when it goes.
  final Widget Function(BuildContext context, FocusNode focusNode) builder;

  @override
  State<BgeExpansionsRow> createState() => _BgeExpansionsRowState();
}

class _BgeExpansionsRowState extends State<BgeExpansionsRow> {
  final _tileFocusNode = FocusNode(debugLabel: 'BgeExpansionsRow.tile');
  final _controlFocusNode = FocusNode(debugLabel: 'BgeRowExpansionsControl');

  /// The expansions an inert row's control still shows after they go while
  /// it holds focus, until the focus has been handed on (#1048).
  BgeCoverExpansions? _leaving;

  @override
  void didUpdateWidget(BgeExpansionsRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.expansions == null || widget.expansions != null) return;
    if (_controlFocusNode.hasFocus) {
      if (_tileFocusNode.canRequestFocus) {
        // Requested before the control's node is detached in this frame,
        // which then hands its focus on to this request (#711).
        _tileFocusNode.requestFocus();
      } else {
        // An inert row's tile takes no focus: past the row, not to the page
        // (#1048). The control stays until the focus has moved on. The
        // node is the one the tile had before this update, so one given
        // something to open in it takes the focus after all.
        _leaving = oldWidget.expansions;
        handFocusOnFromBadge(
          _controlFocusNode,
          owner: _tileFocusNode,
          then: () {
            if (mounted) setState(() => _leaving = null);
          },
        );
      }
    } else {
      // Under a covering route the page's focus history can remember the
      // control, and the pop would give focus to the one before it (#813).
      BgeFocusHandoff.controlLeaving(
        context,
        leaving: _controlFocusNode,
        to: _tileFocusNode,
      );
    }
  }

  @override
  void dispose() {
    _tileFocusNode.dispose();
    _controlFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final expansions = widget.expansions;
    final control = expansions ?? _leaving;
    final tokens = BgeTokens.of(context);
    // A tall row at large text: the badge's drawn edge, inside the room its
    // ring keeps, level with the title's first line.
    final byTitle =
        BgeThumbnail.titleAlignmentOf(context) ==
        ListTileTitleAlignment.titleHeight;
    final ringReach = tokens.focusRingGap + tokens.focusOutlineWidth;
    return Row(
      crossAxisAlignment: byTitle
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        // The same widgets with a control or without, so the tile keeps its
        // element as the control comes and goes.
        Expanded(
          child: MergeSemantics(
            child: Semantics(
              customSemanticsActions: expansions == null
                  ? null
                  : _customActionOf(expansions),
              child: widget.builder(context, _tileFocusNode),
            ),
          ),
        ),
        if (control != null)
          Padding(
            padding: EdgeInsets.only(
              top: byTitle ? tokens.spaceMd - ringReach : 0,
            ),
            child: BgeRowExpansionsControl(
              expansions: control,
              focusNode: _controlFocusNode,
            ),
          ),
      ],
    );
  }
}

/// The control at a list row's end that folds and unfolds a base game's
/// expansions (#1048).
///
/// It is the 🧩 badge a cover carries (`BgeCoverTile.expansions`), with the
/// same look, name, count and expanded state: "Wingspan expansions, 2,
/// collapsed". It is unlike `BgeStackMarker`, which counts copies, not
/// expansions. A tap focuses it, then calls [BgeCoverExpansions.onToggle].
/// Its focus ring is the single tone of a control on a plain surface, as the
/// row has no picture under it.
///
/// ## Where it goes
///
/// [BgeExpansionsRow] places it, and that is the way to use it. It sits
/// beside the row's tile, after it, inside the row's `BgeOutlinedRow` and
/// outside the tile's `MergeSemantics`: a button of its own, a node and a
/// focus stop after the tile's, so that Tab reaches it after the row, and
/// Enter on the row still opens the game. The tile, inside its
/// `MergeSemantics`, offers the same toggle ([bgeRowExpansionsAction]), so
/// that a screen reader on the row can fold and unfold it too.
///
/// A row that places the control itself owns its [focusNode] and the
/// tile's, and when [expansions] goes, does what [BgeExpansionsRow] does: if
/// the control's node has focus, it requests focus on the tile, or on an
/// inert row, whose tile can't take it, keeps the control for the rest of
/// the frame and, once the page is laid out, hands the focus to the next
/// stop after the row, else the one before, and otherwise it calls
/// `BgeFocusHandoff.controlLeaving` with the control's node leaving and the
/// tile's in its place. Left alone, focus on a control that goes lands
/// wherever the page was focused before it, such as another game's row, or
/// on the page itself.
///
/// ## Focus as the rows fold
///
/// The base game's row goes in a `BgeFocusHandoff` that names, while it is
/// folded, its nested games in `folded` ([BgeTopRow.nested]), the place its
/// nested rows name in `foldedPlace`, and [foldedControl] as its
/// `foldedControl`. Folding while focus is on a nested row, as the row's
/// custom action can, then hands the focus to this control, not to the top
/// of the list (#813).
class BgeRowExpansionsControl extends StatefulWidget {
  /// Creates the control for [expansions].
  const BgeRowExpansionsControl({
    required this.expansions,
    this.focusNode,
    super.key,
  });

  /// The control's place among a row's controls, as a `BgeFocusHandoff`
  /// counts them: after the row's tile, at 0. The base game's row passes it
  /// as its `BgeFocusHandoff.foldedControl`.
  ///
  /// An inert row's tile takes no focus, and the control is then its first
  /// and only one, which the hand-off falls back to.
  static const int foldedControl = 1;

  /// What the control counts and toggles.
  final BgeCoverExpansions expansions;

  /// The control's focus, which its owner disposes. Null, the control keeps
  /// one of its own, and its row can't tell when it goes while it holds
  /// focus.
  final FocusNode? focusNode;

  @override
  State<BgeRowExpansionsControl> createState() =>
      _BgeRowExpansionsControlState();
}

class _BgeRowExpansionsControlState extends State<BgeRowExpansionsControl> {
  /// The control's own focus, made when no
  /// [BgeRowExpansionsControl.focusNode] is given.
  FocusNode? _ownFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ??
      (_ownFocusNode ??= FocusNode(debugLabel: 'BgeRowExpansionsControl'));

  @override
  void dispose() {
    _ownFocusNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    // Clear of the row's outline, as a tile's trailing widget is.
    padding: EdgeInsetsDirectional.only(end: BgeTokens.of(context).spaceSm),
    child: BgeCoverExpansionsBadge(
      expansions: widget.expansions,
      focusNode: _focusNode,
      overPicture: false,
    ),
  );
}

/// Gives a row the "Show expansions" or "Hide expansions" custom action of
/// [expansions], as a cover offers it (#1048, #711).
///
/// [BgeExpansionsRow] gives its tile this action itself. This is for a row
/// that places its [BgeRowExpansionsControl] itself.
///
/// [child] is the row's tile. Put this inside the row's `MergeSemantics`, so
/// that the action lands on the row's node: outside it, it would land on the
/// node around the row instead.
Widget bgeRowExpansionsAction({
  required BgeCoverExpansions expansions,
  required Widget child,
}) => Semantics(
  customSemanticsActions: _customActionOf(expansions),
  child: child,
);

Map<CustomSemanticsAction, VoidCallback> _customActionOf(
  BgeCoverExpansions expansions,
) => {
  CustomSemanticsAction(
    label: expansions.expanded ? expansions.hideLabel : expansions.showLabel,
  ): expansions.onToggle,
};

/// One entry in a list whose base games fold their nested rows, as
/// [foldNested] lays them out (#1048).
@immutable
sealed class BgeFoldedRow<T> {
  const BgeFoldedRow();

  /// The games this entry draws a row for, in order: a top row's or a
  /// nested row's own game, or a box's games. A top row's nested games are
  /// not among them: they are drawn by the entries after it, while it is
  /// open.
  List<T> get items;
}

/// A top-level row: a base game, or a game nested under none.
final class BgeTopRow<T> extends BgeFoldedRow<T> {
  /// A top-level row of [item], with [nested] games under it, shown while
  /// [open].
  const BgeTopRow(
    this.item, {
    this.nested = const <Never>[],
    this.open = false,
  });

  /// The game.
  final T item;

  @override
  List<T> get items => [item];

  /// The games nested under it, folded or not, in the order they are shown:
  /// what its `BgeFocusHandoff` names as `folded` while it is folded. Empty
  /// for none.
  final List<T> nested;

  /// How many games are nested under it: the count its
  /// [BgeRowExpansionsControl] shows. 0 for none, and no control.
  int get nestedCount => nested.length;

  /// Whether its nested rows are shown, which its control announces as its
  /// expanded state.
  final bool open;

  @override
  bool operator ==(Object other) =>
      other is BgeTopRow<T> &&
      other.item == item &&
      listEquals(other.nested, nested) &&
      other.open == open;

  @override
  int get hashCode =>
      Object.hash(BgeTopRow, item, Object.hashAll(nested), open);

  @override
  String toString() => 'BgeTopRow($item, nested: $nested, open: $open)';
}

/// A row nested under [parent]'s, laid out in the list, for an open base
/// game with no more than [BgeNestedRowsBox.inlineLimit] of them.
final class BgeNestedRow<T> extends BgeFoldedRow<T> {
  /// [item]'s row, nested under [parent]'s.
  const BgeNestedRow(this.parent, this.item);

  /// The base game it is nested under.
  final T parent;

  /// The game.
  final T item;

  @override
  List<T> get items => [item];

  @override
  bool operator ==(Object other) =>
      other is BgeNestedRow<T> && other.parent == parent && other.item == item;

  @override
  int get hashCode => Object.hash(BgeNestedRow, parent, item);

  @override
  String toString() => 'BgeNestedRow($parent, $item)';
}

/// The rows nested under [parent]'s, as one [BgeNestedRowsBox], for an open
/// base game with more than [BgeNestedRowsBox.inlineLimit] of them.
final class BgeNestedBox<T> extends BgeFoldedRow<T> {
  /// [items]' rows, in a box under [parent]'s.
  const BgeNestedBox(this.parent, this.items);

  /// The base game they are nested under.
  final T parent;

  /// The games, in the order they are shown.
  @override
  final List<T> items;

  @override
  bool operator ==(Object other) =>
      other is BgeNestedBox<T> &&
      other.parent == parent &&
      listEquals(other.items, items);

  @override
  int get hashCode => Object.hash(BgeNestedBox, parent, Object.hashAll(items));

  @override
  String toString() => 'BgeNestedBox($parent, $items)';
}

/// Lays out [groups], each a top-level game and the games nested under it,
/// folded or open by [open] (#1048).
///
/// A group whose top game's [idOf] is in [open], with games nested under
/// it, is open. Each group gives its [BgeTopRow] first, then:
///
/// - folded: nothing more;
/// - open, with up to [BgeNestedRowsBox.inlineLimit] nested: a
///   [BgeNestedRow] for each, in order;
/// - open, with more: one [BgeNestedBox] of them all.
///
/// Every base game starts folded, as a cover does, and any number can be
/// open at once. A game in [open] with nothing nested under it is a top row
/// alone, not open.
List<BgeFoldedRow<T>> foldNested<T>({
  required List<(T top, List<T> nested)> groups,
  required Set<Object> open,
  required Object Function(T) idOf,
}) => [
  for (final (top, nested) in groups) ..._fold(top, nested, open, idOf),
];

/// One group of [foldNested].
List<BgeFoldedRow<T>> _fold<T>(
  T top,
  List<T> nested,
  Set<Object> open,
  Object Function(T) idOf,
) {
  final shown = List<T>.unmodifiable(nested);
  if (shown.isEmpty || !open.contains(idOf(top))) {
    return [BgeTopRow<T>(top, nested: shown)];
  }
  return [
    BgeTopRow<T>(top, nested: shown, open: true),
    if (shown.length <= BgeNestedRowsBox.inlineLimit)
      for (final item in shown) BgeNestedRow<T>(top, item)
    else
      BgeNestedBox<T>(top, shown),
  ];
}

/// Which base games of a list show their nested rows (#1048): the open set,
/// by base game id, that a screen's `State` owns, gives to [foldNested] and
/// disposes.
///
/// Every game starts folded. The set lives as long as its owner, so it
/// survives new pages arriving and a sync, and not a switch between a list
/// and thumbnails, whose grid opens one strip at a time.
class BgeOpenRows extends ChangeNotifier {
  final Set<Object> _open = {};

  /// The ids of the open base games, for [foldNested]: a live view, which
  /// follows [toggle] and [retain] and can't be changed through it.
  Set<Object> get open => UnmodifiableSetView(_open);

  /// Whether the base game [id] is open.
  bool isOpen(Object id) => _open.contains(id);

  /// Opens the base game [id] while it is folded, and folds it while it is
  /// open, and tells the listeners.
  void toggle(Object id) {
    if (!_open.remove(id)) _open.add(id);
    notifyListeners();
  }

  /// Keeps open only the base games in [ids], the ones still placed with
  /// nested rows, so that a game that goes, or loses its last nested row,
  /// comes back folded.
  ///
  /// Tells no one, as a game it folds has no open rows left to redraw, so a
  /// build can call it with the games it lays out.
  void retain(Iterable<Object> ids) {
    if (_open.isEmpty) return;
    _open.retainAll(ids.toSet());
  }

  /// Folds every base game, as a switch to thumbnails does: the list comes
  /// back from there folded.
  ///
  /// Tells no one, as [retain] doesn't, so a build can call it.
  void foldAll() => _open.clear();
}

/// The [BgeFocusHandoff]s of a list that [foldNested] lays out, so that a
/// game's focus follows it as its base game folds and unfolds (#1048).
///
/// A screen builds each row itself, and wraps a [BgeTopRow]'s in [topRow]
/// and a [BgeNestedBox] in [box]. The scope round the list asks [isShownIn].
/// Each nested row, in the list or in a box, goes in a `BgeFocusHandoff` of
/// its own game, by [idOf], whose `place` is its base game's [idOf], as
/// [isShownIn] takes it.
///
/// While a base game is folded, its row names its nested games as folded
/// behind its [BgeRowExpansionsControl], so a focused one whose rows fold,
/// in the list or in a box, or that moves under it, is handed to the
/// control, never to the top of the list (#813).
///
/// Where a box is a stop of its own, [boxIsStop], as it is for rows that
/// take no focus (`BgeNestedRowsBox.focusable`), it is an item of the
/// hand-off too, under [boxIdentity], so that focus on it goes to the
/// control when the rows fold, or when they drop to the few the list lays
/// out itself, none of which can take it. Rows that take focus hand it on
/// through their own items, so their box is no item.
final class BgeFoldedHandoffs<T> {
  /// The hand-offs of the games [idOf] names, whose boxes are stops of their
  /// own where [boxIsStop].
  const BgeFoldedHandoffs({required this.idOf, this.boxIsStop = false});

  /// The game an entry stands for: the [BgeFocusHandoff.identity] of its
  /// row, and the place a nested row names.
  final Object Function(T item) idOf;

  /// Whether a box of nested rows is a stop of its own: whether the rows
  /// take no focus.
  final bool boxIsStop;

  /// The identity of the box of base game [parentId]'s nested rows, as an
  /// item of the hand-off.
  static Object boxIdentity(Object parentId) => (nestedBox: parentId);

  /// [child], the row of [row]'s game, as an item of the hand-off.
  BgeFocusHandoff topRow(BgeTopRow<T> row, {required Widget child}) {
    final id = idOf(row.item);
    final nested = row.nested;
    return BgeFocusHandoff(
      identity: id,
      folded: {
        if (!row.open)
          for (final game in nested) idOf(game),
        // The box, wherever it isn't shown: folded, or open with rows the
        // list lays out itself.
        if (boxIsStop &&
            (!row.open || nested.length <= BgeNestedRowsBox.inlineLimit))
          boxIdentity(id),
      },
      foldedPlace: id,
      foldedControl: BgeRowExpansionsControl.foldedControl,
      child: child,
    );
  }

  /// [child], [box]'s `BgeNestedRowsBox`, as an item of the hand-off under
  /// its base game where it is a stop of its own, [boxIsStop].
  ///
  /// Otherwise [child] alone: its rows' own items hand their focus on. An
  /// item round them would take the hand-off from the row a covered page
  /// remembers, as the box leaves while a route covers the page, and give it
  /// to the box (#813).
  ///
  /// So the box's parent changes as [boxIsStop] does. A caller for which
  /// that can change while the box is shown keeps the box's state across it
  /// with a global key on the box.
  Widget box(BgeNestedBox<T> box, {required Widget child}) {
    if (!boxIsStop) return child;
    final parent = idOf(box.parent);
    return BgeFocusHandoff(
      identity: boxIdentity(parent),
      place: parent,
      child: child,
    );
  }

  /// The hand-off scope's lookup over [rows] (#819): whether a game is shown
  /// at a place, its item built or not, by the place its `BgeFocusHandoff`
  /// names.
  ///
  /// Each game at top level, and each nested under a base game that shows
  /// it, in the list or in a box, and where [boxIsStop], the box. One folded
  /// away is not shown there. The scope asks only once a focused item has
  /// left, so the lookup builds its set then.
  bool Function(Object identity, Object? place) isShownIn(
    List<BgeFoldedRow<T>> rows,
  ) {
    Set<(Object, Object?)>? shown;
    return (identity, place) => (shown ??= {
      for (final row in rows) ...[
        for (final item in row.items) (idOf(item), _placeOf(row)),
        if (boxIsStop && row is BgeNestedBox<T>)
          (boxIdentity(idOf(row.parent)), idOf(row.parent)),
      ],
    }).contains((identity, place));
  }

  /// The place [row]'s games name: their base game's, or none at top level.
  Object? _placeOf(BgeFoldedRow<T> row) => switch (row) {
    BgeTopRow() => null,
    BgeNestedRow(:final parent) || BgeNestedBox(:final parent) => idOf(parent),
  };
}
