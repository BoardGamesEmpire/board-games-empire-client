import 'package:flutter/widgets.dart';

/// A sliver list of rows that keep their state when a row above them leaves
/// or arrives (#549).
///
/// ```dart
/// BgePage.slivers(
///   title: Text(l10n.householdListTitle),
///   slivers: [
///     BgeKeyedSliverList<Household>(
///       items: households,
///       keyOf: (household) => HouseholdListScreen.rowKey(household.id),
///       itemBuilder: (context, household) =>
///           _HouseholdRow(household: household, onOpen: onOpen),
///     ),
///   ],
/// )
/// ```
///
/// ## Why the key and the lookup go together
///
/// A `SliverList.builder` matches the rows it already built to the rows it
/// is asked for by **position**. A row that was third and is now second is
/// handed the widget for the new second row, and when the two differ in key
/// the old one's subtree is thrown away, `InkWell`, [FocusNode] and all. A
/// keyboard user on the third row loses their place when any row above it
/// leaves.
///
/// Two things are needed to stop that, and neither is enough alone:
///
/// - **The key has to sit on the list's own child.** A key one level in, on
///   the row's `MergeSemantics`, is invisible to the sliver, which still
///   matches by position.
/// - **The sliver needs a `findChildIndexCallback`.** It is how the sliver
///   asks "where is the row with this key now?" Probed 2026-10-27 with
///   `a b c d` and `c` focused, then `a` removed: a keyed child with no
///   callback still lost its focus, and only the key together with the
///   lookup kept it. `SliverList.list` builds that lookup itself, which is
///   why the stuck-changes screen never had the problem.
///
/// This widget takes both from [keyOf], so a list cannot take the key and
/// forget the lookup.
///
/// ## The key is on the row's wrapper, not the row
///
/// Each child is `KeyedSubtree(key: keyOf(item), child: itemBuilder(...))`,
/// so `find.byKey(keyOf(item))` finds the wrapper. The row widget must not
/// carry the same key: a finder by that key would match both, and a
/// `GlobalKey` would be a duplicate. A row that needs a key for its own
/// reasons takes a different one.
///
/// The keys must be unique among [items] and must identify the thing a row
/// shows, such as an id, not its position.
class BgeKeyedSliverList<T> extends StatelessWidget {
  /// Creates a sliver list with one keyed row per item in [items].
  const BgeKeyedSliverList({
    required this.items,
    required this.keyOf,
    required this.itemBuilder,
    this.semanticIndexOffset = 0,
    super.key,
  });

  /// The rows' items, in the order they are shown.
  final List<T> items;

  /// The key that identifies `item` from one build to the next.
  ///
  /// Called once per item for the lookup, which the sliver makes on every
  /// rebuild that has live rows, and once more for each row built, so it
  /// should be cheap.
  final Key Function(T item) keyOf;

  /// Builds the row for `item`. The row must not carry [keyOf]'s key.
  final Widget Function(BuildContext context, T item) itemBuilder;

  /// Added to each row's semantic index, as `SliverList.builder` does.
  ///
  /// For a list that follows other indexed rows in the same scroll view, so
  /// a screen reader counts on from where they stopped ("item 4 of 9", not
  /// "item 1 of 9" again).
  final int semanticIndexOffset;

  @override
  Widget build(BuildContext context) {
    // Built on the first lookup of this build, not before. The sliver looks
    // up the key of every live row each time it rebuilds, so the map is built
    // once per rebuild that has live rows; waiting only saves a rebuild with
    // none, such as the first. Rebuilt on the next build because `items` may
    // be a different list by then.
    Map<Key, int>? indexByKey;

    return SliverList.builder(
      itemCount: items.length,
      semanticIndexOffset: semanticIndexOffset,
      findChildIndexCallback: (key) {
        indexByKey ??= {
          for (final (index, item) in items.indexed) keyOf(item): index,
        };
        // Null for a key that has gone: the sliver then drops that row.
        return indexByKey![key];
      },
      itemBuilder: (context, index) {
        final item = items[index];
        return KeyedSubtree(
          key: keyOf(item),
          child: itemBuilder(context, item),
        );
      },
    );
  }
}
