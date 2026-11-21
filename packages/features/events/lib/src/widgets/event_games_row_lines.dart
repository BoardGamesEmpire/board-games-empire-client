import 'package:flutter/widgets.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The rows of one of the Games tab's lists, as a sliver (#949): one row to a
/// line, and in an expanded window ([BgeWindowClass.expanded]) two, side by
/// side, each half the line less a gap between them. The last line of an odd
/// count holds one row at that width.
///
/// Rows, not a grid's tiles. A `SliverGrid` gives every tile in a line the
/// same height, and these rows vary with their notes, their markers and the
/// text size, so a grid would clip them or leave gaps. Each of the list's
/// items is a line instead, and each row in it keeps what a row of a
/// [BgeKeyedSliverList] keeps (#549):
///
/// - **Its key**, [keyOf]'s, on a wrapper around it, which the row must not
///   carry too. A line is keyed by its first row's key, set apart from that
///   row's own, and the sliver finds a line again by it after the rows move,
///   so a line that keeps its first row keeps its place.
/// - **Its number among the rows**, not its line's: a screen reader says
///   "3 of 9" of the third row, on the second line ([IndexedSemantics], with
///   the sliver's own indexes, which would count lines, off). The page's
///   `semanticChildCount` counts the rows too. Where one list is shown as
///   several of these, a group each, as the lineup's dates are (#519), each
///   numbers its rows on from the groups before it ([firstIndex]).
/// - **Its focus, as it moves between lines.** As a row before it leaves, a
///   row moves to the end of the line above, or to the start of its own, and
///   each line it leaves or joins is built again. So each row is held under
///   a global key of its own, which carries it across lines, its focus and
///   its state included: a row still built is always moved to its new line,
///   never built again, so focus stays on the control that had it, and so
///   does what the row holds, such as a held press's spinner. Built again, a
///   row moving to an earlier line would be built in its new line before its
///   old one went, and the tab's own nodes for it, its area's and its head's,
///   would go with the new one, so the old row would no longer hold focus as
///   it left: focus on its main action would fall back to the page. The keys
///   are this list's own, so two lists showing the same rows, as two screens
///   of one event in one navigator would, never share one. Each row is also
///   a [BgeFocusHandoff] of [identityOf], all in one [BgeFocusHandoffScope],
///   wired as #949 names them. They would act only for a row built again
///   rather than moved, which this list doesn't do today.
///
/// Reading and Tab go along each line, then down. A screen reader reads a
/// line's rows from its start, and each row is a traversal group of its own,
/// so Tab goes through one row's controls, then the next row's, rather than
/// across the line's heads first.
class EventGamesRowLines<T> extends StatefulWidget {
  const EventGamesRowLines({
    required this.items,
    required this.keyOf,
    required this.identityOf,
    required this.itemBuilder,
    this.firstIndex = 0,
    super.key,
  });

  /// The rows' items, in the order they are shown.
  final List<T> items;

  /// The key that identifies `item` from one build to the next, such as its
  /// id, on a wrapper around its row. Unique among [items].
  final Key Function(T item) keyOf;

  /// What `item` shows, which its row's [BgeFocusHandoff] names.
  final Object Function(T item) identityOf;

  /// Builds the row for `item`. The row must not carry [keyOf]'s key.
  final Widget Function(BuildContext context, T item) itemBuilder;

  /// The number among the page's rows of the first of [items], from 0: the
  /// count of the rows shown above them, in the groups before this one.
  final int firstIndex;

  @override
  State<EventGamesRowLines<T>> createState() => _EventGamesRowLinesState<T>();
}

class _EventGamesRowLinesState<T> extends State<EventGamesRowLines<T>> {
  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final keyOf = widget.keyOf;
    final perLine = BgeWindowClass.of(context) == BgeWindowClass.expanded
        ? 2
        : 1;
    final gap = BgeTokens.of(context).spaceMd;
    final lines = (items.length + perLine - 1) ~/ perLine;

    // A line is keyed by its first row's key, one row to a line or two.
    Key lineKey(int line) => _LineKey(keyOf(items[line * perLine]));

    // The row of the item at [index]: numbered among the rows, as a screen
    // reader counts it; under its key; held under its global key, so that it
    // moves between lines; and a traversal group and a hand-off item of its
    // own. Where it is a line alone, [line] keys it.
    Widget row(BuildContext context, int index, {Key? line}) {
      final item = items[index];
      final key = keyOf(item);
      return IndexedSemantics(
        key: line,
        index: widget.firstIndex + index,
        child: KeyedSubtree(
          key: key,
          child: KeyedSubtree(
            key: _RowKey(this, key),
            child: FocusTraversalGroup(
              child: BgeFocusHandoff(
                identity: widget.identityOf(item),
                child: widget.itemBuilder(context, item),
              ),
            ),
          ),
        ),
      );
    }

    // Built on the first lookup of this build, as `BgeKeyedSliverList`'s is.
    Map<Key, int>? lineByKey;

    return BgeFocusHandoffScope(
      child: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, line) {
            if (perLine == 1) return row(context, line, line: lineKey(line));
            final first = line * perLine;
            return Row(
              key: lineKey(line),
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: gap,
              children: [
                for (var index = first; index < first + perLine; index++)
                  if (index < items.length)
                    Expanded(child: row(context, index))
                  else
                    // Holds a lone last row to a row's width.
                    const Spacer(),
              ],
            );
          },
          childCount: lines,
          // Each row says its own index: the sliver's would count lines.
          addSemanticIndexes: false,
          findChildIndexCallback: (key) {
            lineByKey ??= {
              for (var line = 0; line < lines; line++) lineKey(line): line,
            };
            // Null for a line that has gone: the sliver then drops it.
            return lineByKey![key];
          },
        ),
      ),
    );
  }
}

/// A line's key: its first row's, set apart from the key on that row's own
/// wrapper, which a finder by the row's key would otherwise find twice.
class _LineKey extends ValueKey<Key> {
  const _LineKey(super.value);
}

/// A row's key across the lines it moves between: [key], the list's for it,
/// within the list [lines] alone.
class _RowKey extends GlobalKey {
  const _RowKey(this.lines, this.key) : super.constructor();

  final State lines;
  final Key key;

  @override
  bool operator ==(Object other) =>
      other is _RowKey && identical(other.lines, lines) && other.key == key;

  @override
  int get hashCode => Object.hash(identityHashCode(lines), key);
}
