import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// The scroll actions a **vertical** viewport offers.
///
/// Both are needed, and taking only one is the bug #257 was filed for: for a
/// vertical viewport `scrollUp` is offered only while there is content further
/// on, and `scrollDown` only while there is content behind. A viewport scrolled
/// to the end therefore exposes `scrollDown` and **not** `scrollUp`, so a walk
/// matching `scrollUp` alone finds no scrolling node and reports `null` — which
/// is indistinguishable from the regression such a walk exists to catch.
const kVerticalScrollActions = <SemanticsAction>{
  SemanticsAction.scrollUp,
  SemanticsAction.scrollDown,
};

/// The scroll actions a **horizontal** viewport offers.
///
/// Nothing in the tree scrolls horizontally yet, so this is not the default.
/// It exists so that when something does, the change is an argument at the call
/// site rather than an edit to [scrollChildCountOnScrollingNode] — which is how
/// the two copies this replaces came to disagree (#354 D3).
const kHorizontalScrollActions = <SemanticsAction>{
  SemanticsAction.scrollLeft,
  SemanticsAction.scrollRight,
};

/// The count a screen reader reads as "item 3 of 9", taken off the node that
/// **actually scrolls**.
///
/// Walked rather than fetched with `tester.getSemantics`, and this is the part
/// worth not re-deriving from memory: `getSemantics` resolves to the nearest
/// merged ancestor, which is not the viewport's node. It reports `null` whether
/// or not the count is wired, so an assertion built on it passes for the broken
/// case.
///
/// Returns `null` when no node matching [scrollActions] carries a count — which
/// is the failure this is usually asserted against, so prefer `isNotNull` over
/// a bare equality check at the call site.
///
/// A missing semantics tree is a different thing and throws rather than
/// returning `null`, because a `null` there would be indistinguishable from
/// "the count is not wired" — the confusion #257 exists to end. Measured on
/// Flutter 3.47.1, that branch is unreachable from a widget test: the test
/// binding reports `semanticsEnabled` and exposes one pipeline owner with a
/// root node in every state — before any `pumpWidget`, with no
/// `SemanticsHandle` taken, and after one is disposed. It is a guard on a
/// framework invariant this helper does not control, not a supported mode.
int? scrollChildCountOnScrollingNode(
  WidgetTester tester, {
  Set<SemanticsAction> scrollActions = kVerticalScrollActions,
}) {
  SemanticsNode? root;
  tester.binding.rootPipelineOwner.visitChildren((owner) {
    root ??= owner.semanticsOwner?.rootSemanticsNode;
  });

  int? found;
  void walk(SemanticsNode node) {
    final data = node.getSemanticsData();
    if (scrollActions.any(data.hasAction) && node.scrollChildCount != null) {
      found = node.scrollChildCount;
    }
    node.visitChildren((child) {
      walk(child);
      return true;
    });
  }

  final tree = root;
  if (tree == null) {
    throw StateError(
      'no root semantics node, so this cannot answer whether the count is '
      'wired. The test binding normally keeps semantics enabled; if that has '
      'changed, take a handle with `tester.ensureSemantics()` before pumping.',
    );
  }

  walk(tree);
  return found;
}
