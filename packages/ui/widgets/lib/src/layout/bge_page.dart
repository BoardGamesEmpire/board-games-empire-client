import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The standard page scaffold: a scrollable, width-constrained, centered
/// content column inside a [Scaffold] (#165).
///
/// Replaces a block that was hand-rolled in every page-shaped screen —
/// `Scaffold` → `SafeArea` → `Center` → `SingleChildScrollView` →
/// `ConstrainedBox(maxWidth: 480)` — each with its own hand-typed padding and
/// its own decision about whether to scroll. All 10 such screens now use this;
/// the literal `480` is [BgeTokens.contentMaxWidth] and the padding is on the
/// spacing scale.
///
/// ```dart
/// BgePage(
///   title: Text(l10n.createHouseholdTitle),
///   child: const CreateHouseholdForm(),
/// )
/// ```
///
/// ## Why the content column is constrained
///
/// Desktop and browser are first-class targets. An unconstrained form stretches
/// its fields to the full width of a 27" monitor, which is both ugly and
/// genuinely harder to use — the eye loses the line, and a label ends up a
/// forearm away from its input. 480dp keeps a comfortable measure while staying
/// wider than any phone, so the constraint is inert on mobile.
///
/// ## Scrolling is the default, not an option
///
/// The content is always scrollable, even when it fits. At the 200% OS text
/// scale the app guarantees (`BgeTextScale.maxScaleFactor`), content that fit
/// comfortably at 1.0 no longer does — and a non-scrolling page at that scale
/// does not merely look wrong, it renders the bottom of the form permanently
/// unreachable. Making scroll opt-out would mean each new screen re-deciding a
/// question that has one correct answer.
class BgePage extends StatelessWidget {
  /// Creates a standard page.
  const BgePage({
    required this.child,
    this.title,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.drawer,
    this.scaffoldKey,
    this.padding,
    this.centerVertically = false,
    this.scrollController,
    super.key,
  });

  /// The page's content. Placed in the constrained, centered column.
  final Widget child;

  /// [AppBar.title]. When null, no app bar is shown — for screens that own
  /// their full surface, like splash and the auth screen.
  final Widget? title;

  /// [AppBar.actions].
  final List<Widget>? actions;

  /// [AppBar.leading].
  final Widget? leading;

  /// Whether the app bar supplies its own back button.
  final bool automaticallyImplyLeading;

  /// Optional [Scaffold.floatingActionButton].
  final Widget? floatingActionButton;

  /// Optional [Scaffold.bottomNavigationBar].
  final Widget? bottomNavigationBar;

  /// Optional [Scaffold.drawer].
  final Widget? drawer;

  /// Key on the underlying [Scaffold].
  ///
  /// A drawer is not a route, so it is closed through the [ScaffoldState]
  /// rather than by popping the navigator — which needs a handle on the
  /// Scaffold this widget owns.
  final GlobalKey<ScaffoldState>? scaffoldKey;

  /// Content padding. Defaults to `spaceLg` on all sides.
  final EdgeInsetsGeometry? padding;

  /// Whether to center the content vertically when it is shorter than the
  /// viewport.
  ///
  /// False by default — content starts at the top, which is what a form or a
  /// list wants. True suits a short, standalone message: an error, an empty
  /// state, a placeholder.
  final bool centerVertically;

  /// Optional controller for the content scroll view.
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    final resolvedPadding = padding ?? EdgeInsets.all(tokens.spaceLg);

    Widget content = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: tokens.contentMaxWidth),
      child: child,
    );

    if (centerVertically) {
      // LayoutBuilder + IntrinsicHeight would also center, but costs an extra
      // layout pass on every scroll. A minimum-height box inside the scroll
      // view centers short content while still letting tall content scroll.
      content = Center(child: content);
    }

    return Scaffold(
      key: scaffoldKey,
      drawer: drawer,
      appBar: title == null
          ? null
          : AppBar(
              title: title,
              actions: actions,
              leading: leading,
              automaticallyImplyLeading: automaticallyImplyLeading,
            ),
      floatingActionButton: floatingActionButton,
      bottomNavigationBar: bottomNavigationBar,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              controller: scrollController,
              padding: resolvedPadding,
              child: ConstrainedBox(
                // Guarantees the content can fill the viewport when it is
                // short (so `centerVertically` has room to work) without
                // capping it when it is tall.
                constraints: BoxConstraints(
                  minHeight: centerVertically
                      ? constraints.maxHeight -
                            resolvedPadding.vertical.clamp(
                              0,
                              constraints.maxHeight,
                            )
                      : 0,
                ),
                child: Align(
                  alignment: centerVertically
                      ? Alignment.center
                      : Alignment.topCenter,
                  child: content,
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
