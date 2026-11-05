import 'package:flutter/widgets.dart';

/// The children of `BgeKeyedSliverList` and `BgeKeyedSliverGrid`: each
/// item's child under its own key, and the lookup that finds a key's child
/// again after the items move (#549). Their docs say why the two go
/// together.
///
/// One delegate for both, so that a fix to how a keyed child is found again
/// reaches the list and the grid alike.
SliverChildBuilderDelegate bgeKeyedChildDelegate<T>({
  required List<T> items,
  required Key Function(T item) keyOf,
  required Widget Function(BuildContext context, T item) itemBuilder,
  required int semanticIndexOffset,
}) {
  // Built on the first lookup of this build, not before. The sliver looks up
  // the key of every live child each time it rebuilds, so the map is built
  // once per rebuild that has live children; waiting only saves a rebuild
  // with none, such as the first. Built again for the next build, because
  // `items` may be a different list by then.
  Map<Key, int>? indexByKey;

  return SliverChildBuilderDelegate(
    (context, index) {
      final item = items[index];
      return KeyedSubtree(key: keyOf(item), child: itemBuilder(context, item));
    },
    childCount: items.length,
    semanticIndexOffset: semanticIndexOffset,
    findChildIndexCallback: (key) {
      indexByKey ??= {
        for (final (index, item) in items.indexed) keyOf(item): index,
      };
      // Null for a key that has gone: the sliver then drops that child.
      return indexByKey![key];
    },
  );
}
