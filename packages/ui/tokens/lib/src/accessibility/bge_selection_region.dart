import 'package:flutter/material.dart';

import 'package:ui_tokens/src/accessibility/bge_selection.dart';

/// The app-wide text-selection region (#322), on the platforms that get one.
///
/// One widget for every place a screen is hosted under the region: `BgeApp`
/// places it above the router's Navigator, and the test helpers that render
/// a screen under it (#338) place it in the same slot of their own
/// `MaterialApp`. The wrapping order below is load-bearing, so a test that
/// restated it would be checking its own copy rather than the app's.
///
/// Gated on [BgeSelection.isEnabledOn], read from `Theme.of(context).platform`
/// for the reasons given there. Off the gate, this is [child] and nothing
/// else.
///
/// **The `Overlay.wrap` is load-bearing, and the order is too.** The region
/// is built to sit above a Navigator, so that it reaches every route, and
/// there is no Overlay ancestor there: the Navigator's own Overlay is below
/// it. `SelectableRegion.build` asserts `debugCheckHasOverlay`, so a bare
/// `SelectionArea` throws on its first build — and `SelectionArea` wrapped
/// *around* `Overlay.wrap` throws for the same reason, since the region
/// still has no Overlay above it. It has to be this way round.
///
/// One further consequence of that `Overlay.wrap`, easy to miss because it
/// is invisible today: above a Navigator it becomes the app's **root**
/// overlay. Without it, the Navigator owns the outermost one, so
/// `Overlay.of(context, rootOverlay: true)` resolves there and its entries
/// come down with a route pop. Under the region they resolve above the
/// Navigator and survive it — so a `MenuAnchor(useRootOverlay: true)`, or
/// anything else reaching for the root overlay to host a layer, would strand
/// its entry over the next screen. Nothing in the app does that yet.
///
/// Anything drag-interactive under the region wraps itself in
/// `SelectionContainer.disabled`, and is checked with a mouse on a pointer
/// platform. The wrapper keeps the surface's own text out of any selection,
/// so a drag the region wins cannot select it. It does not take the region
/// out of the gesture arena — the region's recognizers sit on one detector
/// around its whole subtree — so the surface's drag still has to win, which
/// only the mouse check shows. `BgeShelf`'s widened `dragDevices` win it
/// (#338). Nothing enforces this rule yet; #857 tracks giving it a
/// mechanism.
class BgeSelectionRegion extends StatelessWidget {
  /// Makes [child] selectable on a pointer platform.
  const BgeSelectionRegion({required this.child, super.key});

  /// What the region covers. In `BgeApp`, the router's content.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!BgeSelection.isEnabledOn(Theme.of(context).platform)) return child;
    return Overlay.wrap(child: SelectionArea(child: child));
  }
}
