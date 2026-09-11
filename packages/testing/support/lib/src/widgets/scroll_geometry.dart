import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The render box of the page's scroll viewport.
///
/// `.first` because a screen may nest scrollables; the page's own viewport is
/// the outermost, and it is the space these measurements are taken in.
RenderBox scrollViewportOf(WidgetTester tester) =>
    tester.renderObject<RenderBox>(find.byType(Scrollable).first);

/// The state of the page's scroll viewport, for asserting against its
/// [ScrollPosition] — an offset, extent or overscroll rather than a position
/// in the viewport's space.
///
/// `.first` for the same reason as [scrollViewportOf].
ScrollableState pageScrollOf(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first);

/// The top edge of [target] in the scroll viewport's own coordinate space.
///
/// Geometry rather than `findsOneWidget`, which passes for a widget scrolled
/// clean out of the viewport — the bug in #209, and the reason no
/// `findsOneWidget` assertion could catch it. A widget scrolled past sits in
/// the tree with a **negative** top edge.
///
/// Assert a position against this, not a boolean. A predicate of the form
/// "is it on screen" restates the widget's own guard, which makes a test that
/// cannot fail for any implementation satisfying it — raised in review on
/// #209 and settled there (#354 D4).
double topInViewport(WidgetTester tester, Finder target) => tester
    .renderObject<RenderBox>(target)
    .localToGlobal(Offset.zero, ancestor: scrollViewportOf(tester))
    .dy;
