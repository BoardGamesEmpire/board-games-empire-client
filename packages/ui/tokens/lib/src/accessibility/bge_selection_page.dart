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
/// **Until it has shown, a page hands its text no registrar at all.** A
/// scroll view puts a selection container of its own under any registrar
/// it finds, and that container sorts its own text the same way, whatever
/// the registrar above it does with the container. Most pages scroll. With
/// no registrar the scroll view makes no container, and the text
/// registers nowhere. Once the page shows, the scroll view makes its
/// container, and builds what is beneath it afresh, which nobody has seen
/// yet. The page itself is kept, by a [GlobalKey].
///
/// **After that, the registrar changes and the shape doesn't.** A page
/// that has shown and is covered was laid out, and its text has a
/// position. It keeps a [SelectionRegistrarScope] whose registrar changes,
/// so the scroll view keeps its container. Taking the registrar away there
/// too would build everything beneath each scroll view afresh every time
/// the page was covered, and lose what the user had done in it.
///
/// With no region above (a touch platform, or the frame before the
/// region mounts), this is [child] and nothing else.
class BgeSelectionPage extends StatefulWidget {
  /// Keeps [child] out of the region while it is hidden.
  const BgeSelectionPage({required this.child, super.key});

  /// The page.
  final Widget child;

  @override
  State<BgeSelectionPage> createState() => _BgeSelectionPageState();
}

class _BgeSelectionPageState extends State<BgeSelectionPage> {
  /// Keeps the page across a change of what is above it.
  final GlobalKey _page = GlobalKey(debugLabel: 'BgeSelectionPage');

  /// Whether the page has shown, and so been laid out.
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    final page = KeyedSubtree(key: _page, child: widget.child);
    final region = SelectionContainer.maybeOf(context);
    if (region == null) return page;
    final showing = TickerMode.valuesOf(context).enabled;
    _shown |= showing;
    if (!_shown) return SelectionContainer.disabled(child: page);
    return SelectionRegistrarScope(
      registrar: showing ? region : const _NoRegion(),
      child: page,
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
