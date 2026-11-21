import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart' show BgeFocusRing;

/// Gives the focus stop at [words] the keyboard's focus, and says whether the
/// ring around it shows (#758).
///
/// [words] is any widget inside the row, such as its title. The nearest
/// `Focus` above it takes focus, and the highlight mode is forced to the
/// keyboard's, then restored in a tear-down. Expects exactly one
/// [BgeFocusRing] above [words], so a row with none fails here. Expects the
/// ring hidden in the frame already built, before the row has focus, so a
/// ring that always shows fails here too. It checks that frame only: the
/// forced highlight mode hasn't rebuilt it yet, so a ring that shows at rest
/// only in the keyboard's mode isn't caught.
Future<bool> keyboardFocusShowsRing(WidgetTester tester, Finder words) async {
  FocusManager.instance.highlightStrategy =
      FocusHighlightStrategy.alwaysTraditional;
  addTearDown(
    () => FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.automatic,
  );

  final ring = find.ancestor(of: words, matching: find.byType(BgeFocusRing));
  expect(ring, findsOneWidget, reason: 'the row sits in a ring');
  expect(
    _ringDrawn(tester, ring),
    isFalse,
    reason: 'the ring is hidden while the row is at rest',
  );

  Focus.of(tester.element(words)).requestFocus();
  await tester.pump();
  return _ringDrawn(tester, ring);
}

bool _ringDrawn(WidgetTester tester, Finder ring) {
  // The ring's own outer box comes first in the ring's subtree, ahead of its
  // inner tone's box and of anything the content draws.
  final drawn = tester.widget<DecoratedBox>(
    find.descendant(of: ring, matching: find.byType(DecoratedBox)).first,
  );
  return (drawn.decoration as BoxDecoration).border != null;
}
