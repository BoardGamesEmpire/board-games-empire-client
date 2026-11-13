import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'package:ui_tokens/src/accessibility/bge_selection_region.dart';

/// A page's place in the app-wide [BgeSelectionRegion]: in it while the
/// page shows, out of it while a page above hides it.
///
/// Wraps every page a Navigator under the region shows. The router's
/// one page builder does it, so no page can miss it.
///
/// **Why a hidden page leaves the region.** The region sits above the
/// Navigator, so every page's text registers with it, the hidden pages'
/// too. Each time a text is added, the region sorts it into screen order
/// by its position. A page that the Navigator adds *beneath* the top
/// page, in the same change that adds the top one, is built but never
/// laid out: the Overlay lays out only the entries that show. Its text
/// has no position, and the sort throws (`RenderBox was not laid out`).
/// A browser Back that rebuilds a stack of pages at once does this
/// (#611). It is a gap in the framework's region, but a page can't be
/// laid out while hidden, so the page has to stay out of the sort.
///
/// The Overlay builds a hidden entry with its tickers off, so
/// [TickerMode] is what tells a hidden page here. A hidden page also has
/// nothing anyone could select, so leaving the region costs nothing.
///
/// The tree has the same shape either way: a [SelectionRegistrarScope]
/// whose registrar changes. A shape change would build the page afresh
/// each time it was covered, and lose its state.
///
/// With no region above (a touch platform, or the frame before the
/// region mounts), this is [child] and nothing else.
class BgeSelectionPage extends StatelessWidget {
  /// Keeps [child] out of the region while it is hidden.
  const BgeSelectionPage({required this.child, super.key});

  /// The page.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final region = SelectionContainer.maybeOf(context);
    if (region == null) return child;
    return SelectionRegistrarScope(
      registrar: TickerMode.valuesOf(context).enabled
          ? region
          : const _NoRegion(),
      child: child,
    );
  }
}

/// Where a hidden page's text registers: nowhere.
class _NoRegion implements SelectionRegistrar {
  const _NoRegion();

  @override
  void add(Selectable selectable) {}

  @override
  void remove(Selectable selectable) {}
}
