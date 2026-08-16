import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The largest share of the viewport a [BgePage.footer] may take.
///
/// Named rather than written inline: it is a proportion, not a spacing or
/// width decision, so there is no token for it — but an unexplained `/ 2`
/// in a constraint reads like one.
///
/// Exists because the footer sits outside the scroll view, so an unbounded
/// one starves the content above it. Half leaves the content at least half.
const double _footerMaxViewportFraction = 0.5;

/// Which measure caps a [BgePage]'s content column.
enum BgePageWidth {
  /// A reading measure ([BgeTokens.contentMaxWidth]). Forms and prose — the
  /// default, and correct for most screens.
  form,

  /// A wider measure ([BgeTokens.paneMaxWidth]) for list and pane surfaces,
  /// whose rows are a label plus a trailing control rather than a line to be
  /// read. Still capped: no surface stretches to the width of a monitor.
  pane,
}

/// The standard page scaffold: a scrollable, width-constrained, centered
/// content column inside a [Scaffold] (#165).
///
/// Replaces a block that was hand-rolled in every page-shaped screen —
/// `Scaffold` → `SafeArea` → `Center` → `SingleChildScrollView` →
/// `ConstrainedBox(maxWidth: 480)` — each with its own hand-typed padding and
/// its own decision about whether to scroll. All 12 such screens now use
/// this; the widths are [BgeTokens.contentMaxWidth] and [BgeTokens.paneMaxWidth]
/// (see [BgePageWidth]) and the padding is on the spacing scale.
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
///
/// ## Why the width variant is a cap, not a breakpoint
///
/// [BgePageWidth] selects between two *measures*, and each is applied as a
/// maximum. A cap is already adaptive: on a 360dp phone a page capped at 840
/// simply fills the window, and the same widget on a 2560px monitor stops at
/// 840. No `LayoutBuilder`, no window-class check, no second layout path to
/// keep in sync.
///
/// Reaching for [BgeTokens.breakpointMedium] here would have been the wrong
/// primitive. Breakpoints answer "at what width should this change form?" —
/// rail versus bottom bar, one pane versus two. Width answers "how wide should
/// this grow?" Those are different questions, and wiring a threshold into a
/// measure would mean retuning a breakpoint silently resizes every list
/// surface.
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
    this.width = BgePageWidth.form,
    this.footer,
    this.scrollController,
    super.key,
  }) : slivers = null,
       semanticChildCount = null,
       assert(
         footer == null || floatingActionButton == null,
         'A footer and a floatingActionButton both sit at the bottom of the '
         'body, and the FAB floats over it — the FAB would cover the end of '
         'the footer and eat its taps. Pick one.',
       );

  /// Creates a page whose content is slivers rather than a single box.
  ///
  /// Use this for a **list surface**. A `ListView` placed in [child] has to be
  /// shrink-wrapped and made non-scrollable, because the box constructor
  /// already supplies a scroll view — and that splits the collection
  /// semantics: measured, the scrollable node loses its `scrollChildCount`
  /// while the node that still carries it cannot scroll, so a screen reader
  /// stops saying "item 3 of 9". It also forfeits the sliver's per-viewport
  /// realization.
  ///
  /// This constructor gives the page one real viewport, so a `SliverList`
  /// keeps both.
  ///
  /// ```dart
  /// BgePage.slivers(
  ///   title: Text(l10n.settingsTitle),
  ///   width: BgePageWidth.pane,
  ///   slivers: [SliverList.list(children: rows)],
  /// )
  /// ```
  const BgePage.slivers({
    required List<Widget> this.slivers,
    this.semanticChildCount,
    this.title,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.drawer,
    this.scaffoldKey,
    this.padding,
    this.width = BgePageWidth.form,
    this.footer,
    this.scrollController,
    super.key,
  }) : child = null,
       // Vertical centring is a box idea — it needs the content's height,
       // which a lazy sliver list does not have. A list surface starts at
       // the top anyway.
       centerVertically = false,
       assert(
         footer == null || floatingActionButton == null,
         'A footer and a floatingActionButton both sit at the bottom of the '
         'body, and the FAB floats over it — the FAB would cover the end of '
         'the footer and eat its taps. Pick one.',
       );

  /// The page's content, for the box constructor. Placed in the constrained,
  /// centered column. Null when built with [BgePage.slivers].
  final Widget? child;

  /// The page's content, for [BgePage.slivers]. Null otherwise.
  final List<Widget>? slivers;

  /// How many items the slivers hold, for [BgePage.slivers].
  ///
  /// This is what a screen reader reads as "item 3 of 9". `ListView(children:)`
  /// infers it from the list length, but `CustomScrollView` cannot — its
  /// slivers may be lazy or unbounded — so a list surface has to say. Leave
  /// null only when the count genuinely is not known.
  final int? semanticChildCount;

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

  /// Which measure caps the content column. Defaults to
  /// [BgePageWidth.form].
  final BgePageWidth width;

  /// A pinned action area below the scrolling content — typically a submit
  /// button.
  ///
  /// Distinct from [bottomNavigationBar], which spans the window by Material
  /// convention. This belongs to the content column and is held to the same
  /// measure, so a submit button stays under the form it submits instead of
  /// drifting to the edge of a monitor.
  ///
  /// Pinned rather than placed at the end of the content because an action
  /// that scrolls out of reach on a long form is the failure this prevents.
  ///
  /// Cannot be combined with [floatingActionButton]: Scaffold floats the FAB
  /// over the body, so it lands on top of the footer band and swallows taps
  /// on its trailing end. Asserted rather than documented-and-hoped, because
  /// the overlap is invisible until someone taps the wrong half of a button.
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    final resolvedPadding = padding ?? EdgeInsets.all(tokens.spaceLg);

    final maxWidth = switch (width) {
      BgePageWidth.form => tokens.contentMaxWidth,
      BgePageWidth.pane => tokens.paneMaxWidth,
    };

    Widget content = ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
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
        child: footer == null
            // No footer is the common case — 11 of the 12 page screens. Skip
            // the flex entirely rather than make every one of them lay out a
            // Column with a single child.
            ? _pageContent(content, resolvedPadding, maxWidth)
            : LayoutBuilder(
                builder: (context, constraints) => Column(
                  // Stretch so the footer's own cap decides its width. Left
                  // to shrink-wrap it would centre at its intrinsic width
                  // and stop lining up with the column above it.
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _pageContent(content, resolvedPadding, maxWidth),
                    ),
                    ConstrainedBox(
                      // The footer is not in the scroll view, so an
                      // unbounded one starves the Expanded above it: a tall
                      // footer at 200% text scale drove the scroll view to
                      // zero height and made the whole page unreachable —
                      // the failure the scroll guarantee exists to prevent.
                      constraints: BoxConstraints(
                        maxHeight:
                            constraints.maxHeight * _footerMaxViewportFraction,
                      ),
                      // Scrollable, because the cap alone only trades one
                      // unreachable region for another: a note plus a button
                      // at 200% text scale overflowed the cap and put the
                      // button 400dp below the window. The same reasoning as
                      // the page's own scroll view — a footer that fits at
                      // 1.0 does not at 2.0 — so it shrink-wraps when short
                      // and scrolls when it is not.
                      child: SingleChildScrollView(
                        child: Padding(
                          // The content's own horizontal inset so the footer
                          // lines up with the column above it, and its bottom
                          // inset so the action is not flush against the
                          // window edge. The top is dropped because the footer
                          // is a band against the content, not a floating
                          // card — a page that wants a visible separation
                          // should put a Divider in the footer, since the
                          // scroll view's own bottom padding scrolls away with
                          // the content and cannot supply one.
                          padding: resolvedPadding
                              .resolve(Directionality.of(context))
                              .copyWith(top: 0),
                          // `heightFactor: 1` so this shrink-wraps vertically.
                          // Without it the Align fills the cap above, and the
                          // footer band is always half the viewport — a 48dp
                          // button stranded mid-band with the content squeezed
                          // into the top half. The cap bounds the footer; it
                          // must not size it.
                          child: Align(
                            heightFactor: 1,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: maxWidth),
                              child: footer,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _pageContent(
    Widget content,
    EdgeInsetsGeometry resolvedPadding,
    double maxWidth,
  ) => slivers == null
      ? _scrollingContent(content, resolvedPadding)
      : _sliverContent(resolvedPadding, maxWidth);

  /// One real viewport over the caller's slivers.
  ///
  /// The measure is applied as symmetric padding rather than a constraining
  /// sliver, because a sliver constrained on the cross axis aligns to the
  /// leading edge — the content column has to stay centred, the way the box
  /// path centres it.
  Widget _sliverContent(EdgeInsetsGeometry resolvedPadding, double maxWidth) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final resolved = resolvedPadding.resolve(Directionality.of(context));
          final available = constraints.maxWidth - resolved.horizontal;
          final gutter = math.max(0.0, (available - maxWidth) / 2);
          return CustomScrollView(
            controller: scrollController,
            semanticChildCount: semanticChildCount,
            slivers: [
              SliverPadding(
                padding: resolved.add(EdgeInsets.symmetric(horizontal: gutter)),
                sliver: SliverMainAxisGroup(slivers: slivers!),
              ),
            ],
          );
        },
      );

  Widget _scrollingContent(
    Widget content,
    EdgeInsetsGeometry resolvedPadding,
  ) => LayoutBuilder(
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
                      resolvedPadding.vertical.clamp(0, constraints.maxHeight)
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
  );
}
