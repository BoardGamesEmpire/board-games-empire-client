import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

// Scroll helpers for an `auditScreen` call's `arrange` (#50). Flutter's
// guidelines measure only what is on screen, so a state whose controls run
// below the fold is audited a second time scrolled, or in a view tall enough
// to hold it all. Each helper checks that it got where it was sent: a scroll
// that silently fell short would repeat the unscrolled call without saying
// so.
//
// The page's own scrollable is taken to be the first in the tree: a field's
// inner one sits beneath it.

/// Scrolls the page to its end, for what a state leaves below the fold at
/// 320dp × 2.0, and checks that it got there (#50).
///
/// Settled first, because a pump after the jump (a field's caret reveal, say)
/// could pull the page back up.
///
/// Only at the narrow viewport, where the fold is. A page a few dp taller than
/// the wider view would, at its end, leave a field a sliver high under the top
/// edge, and Flutter's tap-target check fails that sliver at its clipped size.
/// The wider cells are left at the top, as the unscrolled call has them, with
/// the page's controls whole.
Future<void> scrollPageToEnd(WidgetTester tester) async {
  await tester.pumpAndSettle();
  if (tester.view.physicalSize.width / tester.view.devicePixelRatio > 320) {
    return;
  }
  final position = _pagePosition(tester);
  position.jumpTo(position.maxScrollExtent);
  await tester.pumpAndSettle();
  expect(position.maxScrollExtent, greaterThan(0), reason: 'nothing to scroll');
  expect(position.pixels, position.maxScrollExtent);
}

/// Scrolls a lazily built list to its end until [last] has been built, and
/// checks that the page is at its end (#50).
///
/// A list's extent grows as it is scrolled, so one jump isn't the end; this
/// repeats until [last] exists. Unlike [scrollPageToEnd] it runs at every
/// viewport. With [mustScroll], the default, it also checks that the list ran
/// below the fold, so the call audits something the unscrolled one can't see;
/// pass false for a state whose list fits the wider viewports.
Future<void> scrollListToEnd(
  WidgetTester tester,
  Finder last, {
  bool mustScroll = true,
}) async {
  await tester.pumpAndSettle();
  final position = _pagePosition(tester);
  for (var i = 0; i < 20 && last.evaluate().isEmpty; i++) {
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();
  }
  position.jumpTo(position.maxScrollExtent);
  await tester.pumpAndSettle();
  expect(last, findsOneWidget);
  if (mustScroll) {
    expect(
      position.maxScrollExtent,
      greaterThan(0),
      reason: 'nothing to scroll',
    );
  }
  expect(position.pixels, position.maxScrollExtent);
}

/// Scrolls the page back to its top, and checks that it is there (#50).
///
/// For a state reached by tapping something below the fold: the tap scrolls
/// the page to it, and that can leave a control clipped by the top edge,
/// which Flutter's tap-target check fails at its clipped size. The state
/// itself is kept; the call then audits the page as a user first sees it.
Future<void> scrollPageToTop(WidgetTester tester) async {
  await tester.pumpAndSettle();
  final position = _pagePosition(tester)..jumpTo(0);
  await tester.pumpAndSettle();
  expect(position.pixels, 0);
}

/// Makes the view 6000dp tall, enough to hold any page whole, at the width
/// and text scale it already has (#50).
///
/// For a state whose end-of-page scroll leaves a control half under the top
/// edge, which Flutter's tap-target check fails at its clipped size: audited
/// in a view with nothing below the fold instead. Width and text scale drive
/// the layout; height only decides what is on screen. Call it in `arrange`
/// once the state is reached, then [expectWholePage]. The view is reset by
/// the teardown `useViewSize` registers, which `auditScreen` calls.
Future<void> useWholePage(WidgetTester tester) async {
  final size = tester.view.physicalSize / tester.view.devicePixelRatio;
  tester.view.physicalSize =
      Size(size.width, 6000) * tester.view.devicePixelRatio;
  await tester.pumpAndSettle();
}

/// Checks that nothing is below the fold: the page's scrollable has no extent
/// (#50).
void expectWholePage(WidgetTester tester) {
  expect(
    _pagePosition(tester).maxScrollExtent,
    0,
    reason: 'the page still scrolls',
  );
}

ScrollPosition _pagePosition(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;
