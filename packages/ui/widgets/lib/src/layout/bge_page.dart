import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show BoxParentData, PipelineOwner, RenderShiftedBox, ScrollCacheExtent;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;
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

/// How many viewports of content a [BgePage.slivers] page with a footer keeps
/// built past each edge of its view, where the default is 250dp.
///
/// One is enough because of [_footerMaxViewportFraction]: a footer takes at
/// most half the body, so a row it pushes out of view is at most half the
/// body past the edge, which is no more than the view it leaves.
const double _footerCacheViewports = 1;

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
       semanticChildCount = null;

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
       centerVertically = false;

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
  ///
  /// Scaffold floats it over the body, so the end of the content would scroll
  /// to a place the button covers, and a tap on the last row's covered part
  /// would land on the button instead (#467). The page therefore reserves the
  /// room itself, on both constructors: whenever this is set, the bottom of
  /// the content padding is at least [BgeTokens.spaceXxl] plus
  /// [BgeTokens.spaceLg] plus [BgeTokens.spaceMd].
  ///
  /// That is the button's 56dp plus its 16dp margin, plus a 16dp gap. It is a
  /// floor rather than an addition, so a caller's own [padding] counts towards
  /// it, and a constant because the button's height and margin do not change
  /// with text scale (probed 2026-10-27, see #467).
  ///
  /// Reserved whenever the button is there, not only when rows are. Under a
  /// spinner or an empty state it costs no room at rest on the sliver path,
  /// where content starts at the top and does not move, but a
  /// `SliverFillRemaining` state can then be dragged up by the whole 88dp,
  /// rather than the 24dp of the default padding. On the box path the room
  /// sits inside the scroll padding that [centerVertically] already
  /// subtracts.
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
  /// ## When to pin (#211)
  ///
  /// On a **flow step**, a **long review surface**, or for **the outcome of an
  /// action on a long list or page**, and nowhere else. Today that means
  /// feedback compose and review, and the banners that answer actions on a
  /// DataGateway's page: on the DataGateway itself, and on its language
  /// worklist, stacked in its one footer (#457). Short forms and vertically
  /// centred pages keep their action inline, at the end of the form:
  /// server-add, sign-in, register and create-household.
  ///
  /// - **A flow step pins because the next step does.** Compose hands over
  ///   to review, which pins its send button, and an action that scrolls on
  ///   one step and is pinned on the next moves at the handoff.
  /// - **A review surface pins because it can be any length**, and its action
  ///   is the reason the page exists.
  /// - **A centred first-run page does not.** Auth's column continues past
  ///   its form with the sign-in alternatives, so a pinned "Sign in" would
  ///   render below them. Measured at 320×480 and 200% text, a pinned
  ///   submit band took 100dp of a 424dp body.
  /// - **A short form does not.** Its button already scrolls into reach, and
  ///   a pinned band costs content height for as long as the page is open.
  /// - **An outcome on a long list pins because the list moves on.** Inside
  ///   the list, a banner is built only near the view, so one that lands after
  ///   the user has scrolled away is neither seen nor announced. At the head of
  ///   a long page, a banner takes the page from the control it answers, and
  ///   taking it away moves every control below it. In the footer it is always
  ///   built and on screen, and reveals itself only within the footer's own
  ///   scroll view, so the page doesn't move. Such a footer is passed on every
  ///   build and renders nothing while there is nothing to report: this page
  ///   builds a different tree with a footer than without one, so a footer
  ///   that came and went would lose the scroll position and focus (#457).
  ///
  /// A page that pins may pass a [BgeFormActions] here, so that a failure
  /// still sits on the action it answers.
  ///
  /// Cannot be combined with [floatingActionButton]: Scaffold floats the FAB
  /// over the body, so it lands on top of the footer band and swallows taps
  /// on its trailing end. Asserted rather than documented-and-hoped, because
  /// the overlap is invisible until someone taps the wrong half of a button.
  ///
  /// ## A footer over a lazy list
  ///
  /// A footer that arrives takes room from the end of the view, so the rows
  /// there leave it. On a lazy list a row that far out of view is no longer
  /// built, and keyboard focus on it, or on its way back to it, is lost. So a
  /// [BgePage.slivers] page with a footer keeps one viewport of content built
  /// past each edge of the view, where the default is 250dp. One is enough
  /// because the footer takes at most half the body. A page without a footer
  /// keeps the default (#457).
  ///
  /// ## A footer that gets shorter
  ///
  /// The view gets taller by what the footer gives back, so the end of the
  /// page comes up to meet it. With the page scrolled to its end, that would
  /// drop everything on the page by that height, under a pointer that may be
  /// about to press something. So the band gives back only what the page has
  /// left below the view, and keeps the rest as empty room above what is left
  /// of the footer. That room goes as the page leaves its end, at the pace it
  /// leaves. A page at its start has nothing to drop, and takes it all at
  /// once (#457).
  final Widget? footer;

  /// Rejects a page carrying both a [footer] and a [floatingActionButton]
  /// (#231).
  ///
  /// ## Why this is not an `assert`, and not in the constructor
  ///
  /// It was an `assert` in both constructor initializer lists, which left
  /// the invariant unenforced in exactly the builds users run: `assert`
  /// compiles away outside debug. A `const` invocation was covered — the
  /// analyzer evaluates a const constructor's asserts at compile time — but
  /// a **non-const** one was not, and that is the shape real screens use:
  /// `household_list_screen.dart` builds its FAB from widget state, and
  /// `feedback_review_screen.dart` builds its footer the same way. Neither
  /// is const, so neither was ever checked in release.
  ///
  /// It cannot move to a constructor *body*, because both constructors are
  /// `const` and a const constructor has no body. Making them non-const to
  /// host a throw would break every `const BgePage(...)` call site and cost
  /// the canonicalization on the common path, to guard a case those call
  /// sites cannot even express. So the check runs here, on the build path,
  /// which is compiled in every mode and reached before any layout happens.
  ///
  /// A [FlutterError] (rather than an `ArgumentError`) so it arrives through
  /// the framework's error reporting: the page shows an error widget and the
  /// fault reaches the observability channel (#34), instead of taking the
  /// app down for a layout conflict.
  void _checkBottomSlotExclusivity() {
    if (footer == null || floatingActionButton == null) return;
    throw FlutterError(
      'A footer and a floatingActionButton both sit at the bottom of the '
      'body, and the FAB floats over it — the FAB would cover the end of '
      'the footer and eat its taps. Pick one.',
    );
  }

  @override
  Widget build(BuildContext context) {
    _checkBottomSlotExclusivity();

    final tokens = BgeTokens.of(context);
    final resolvedPadding = padding ?? EdgeInsets.all(tokens.spaceLg);
    // The room the floating button needs at the end of the content, made up
    // once so both scroll paths get it. The footer is not part of it: a page
    // with a button has no footer (see `_checkBottomSlotExclusivity`). The
    // bottom inset does not depend on the text direction, so either one
    // reads it.
    final fabRoom = tokens.spaceXxl + tokens.spaceLg + tokens.spaceMd;
    final bottom = resolvedPadding.resolve(TextDirection.ltr).bottom;
    final contentPadding = floatingActionButton == null || bottom >= fabRoom
        ? resolvedPadding
        : resolvedPadding.add(EdgeInsets.only(bottom: fabRoom - bottom));

    final maxWidth = width.resolve(tokens);

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

    // One traversal group for the scrolling content, so Tab orders it among
    // itself, and places it among the app bar, the floating button and the
    // footer by where the whole view sits (#50). Flutter orders Tab stops by
    // where they are on screen, and content scrolled up under the app bar
    // sits above the back button. Without the group, Shift+Tab up a scrolled
    // form went to the back button between every two fields, Tab from the
    // last field skipped it, and a floating button or the footer came up
    // halfway down a long page. Inside the group the content moves as one,
    // so its own order never changes as it scrolls.
    final page = FocusTraversalGroup(
      child: _pageContent(content, contentPadding, maxWidth),
    );

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
            // No footer is the common case — 10 of the 12 page screens. Skip
            // the flex entirely rather than make every one of them lay out a
            // Column with a single child.
            ? page
            : _PageWithFooter(
                page: page,
                // Scrollable, because the cap alone only trades one
                // unreachable region for another: a note plus a button
                // at 200% text scale overflowed the cap and put the
                // button 400dp below the window. The same reasoning as
                // the page's own scroll view — a footer that fits at
                // 1.0 does not at 2.0 — so it shrink-wraps when short
                // and scrolls when it is not.
                //
                // A traversal group of its own, as the page's content has,
                // and for the same reason (#50): a footer scrolled within
                // its cap puts its first controls up level with the page's,
                // and Tab then went from the page to the footer's second
                // control and back to its first.
                footer: FocusTraversalGroup(
                  child: SingleChildScrollView(
                    // Never the route's primary scroll view, which on
                    // Android and iOS is the page's own. A second one
                    // there leaves the keyboard's page scrolling two
                    // positions to choose from with focus on the page,
                    // as it is when a screen opens: it threw, and the
                    // page didn't move (#457).
                    primary: false,
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
              ),
      ),
    );
  }

  Widget _pageContent(
    Widget content,
    EdgeInsetsGeometry contentPadding,
    double maxWidth,
  ) => slivers == null
      ? _scrollingContent(content, contentPadding)
      : _sliverContent(contentPadding, maxWidth);

  /// One real viewport over the caller's slivers.
  ///
  /// The measure is applied as symmetric padding rather than a constraining
  /// sliver, because a sliver constrained on the cross axis aligns to the
  /// leading edge — the content column has to stay centred, the way the box
  /// path centres it.
  Widget _sliverContent(EdgeInsetsGeometry contentPadding, double maxWidth) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final resolved = contentPadding.resolve(Directionality.of(context));
          final available = constraints.maxWidth - resolved.horizontal;
          final gutter = math.max(0.0, (available - maxWidth) / 2);
          return CustomScrollView(
            controller: scrollController,
            semanticChildCount: semanticChildCount,
            // See "A footer over a lazy list" on [footer].
            scrollCacheExtent: footer == null
                ? null
                : const ScrollCacheExtent.viewport(_footerCacheViewports),
            slivers: [
              SliverPadding(
                padding: resolved.add(EdgeInsets.symmetric(horizontal: gutter)),
                sliver: SliverMainAxisGroup(slivers: slivers!),
              ),
            ],
          );
        },
      );

  Widget _scrollingContent(Widget content, EdgeInsetsGeometry contentPadding) =>
      LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            controller: scrollController,
            padding: contentPadding,
            child: ConstrainedBox(
              // Guarantees the content can fill the viewport when it is
              // short (so `centerVertically` has room to work) without
              // capping it when it is tall.
              constraints: BoxConstraints(
                minHeight: centerVertically
                    ? constraints.maxHeight -
                          contentPadding.vertical.clamp(
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
      );
}

/// A page's content over its footer, capped so that the footer leaves the
/// content at least half the body. See "A footer that gets shorter" on
/// [BgePage.footer] for the room it keeps.
class _PageWithFooter extends StatefulWidget {
  const _PageWithFooter({required this.page, required this.footer});

  final Widget page;
  final Widget footer;

  @override
  State<_PageWithFooter> createState() => _PageWithFooterState();
}

class _PageWithFooterState extends State<_PageWithFooter> {
  /// How the page's own scroll view last reported itself. Null until it has.
  final ValueNotifier<ScrollMetrics?> _pageMetrics = ValueNotifier(null);

  @override
  void dispose() {
    _pageMetrics.dispose();
    super.dispose();
  }

  bool _onPageNotification(Notification notification) {
    final (metrics, depth) = switch (notification) {
      ScrollNotification(:final metrics, :final depth) => (metrics, depth),
      ScrollMetricsNotification(:final metrics, :final depth) => (
        metrics,
        depth,
      ),
      _ => (null, 0),
    };
    // Only the page's own: a horizontal strip on it, or a scroll view inside
    // it, says nothing about where the page is.
    if (metrics != null && depth == 0) _pageMetrics.value = metrics;
    return false;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Column(
      // Stretch so the footer's own cap decides its width. Left to shrink-wrap
      // it would centre at its intrinsic width and stop lining up with the
      // column above it.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: NotificationListener<Notification>(
            onNotification: _onPageNotification,
            child: widget.page,
          ),
        ),
        ConstrainedBox(
          // The footer is not in the scroll view, so an unbounded one starves
          // the Expanded above it: a tall footer at 200% text scale drove the
          // scroll view to zero height and made the whole page unreachable —
          // the failure the scroll guarantee exists to prevent.
          constraints: BoxConstraints(
            maxHeight: constraints.maxHeight * _footerMaxViewportFraction,
          ),
          child: _FooterRoom(pageMetrics: _pageMetrics, child: widget.footer),
        ),
      ],
    ),
  );
}

/// Keeps the room a shorter footer would give back, while giving it back would
/// move the page.
class _FooterRoom extends SingleChildRenderObjectWidget {
  const _FooterRoom({required this.pageMetrics, required super.child});

  final ValueListenable<ScrollMetrics?> pageMetrics;

  @override
  _RenderFooterRoom createRenderObject(BuildContext context) =>
      _RenderFooterRoom(pageMetrics);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFooterRoom renderObject,
  ) => renderObject.pageMetrics = pageMetrics;
}

/// A render object rather than a measure taken after the frame, so the footer
/// that got shorter and the room kept for it are the same frame: the column
/// lays the footer out before the page, and the page never sees a taller view.
class _RenderFooterRoom extends RenderShiftedBox {
  _RenderFooterRoom(this._pageMetrics) : super(null);

  ValueListenable<ScrollMetrics?> _pageMetrics;

  /// Keeping room for the footer now.
  bool _keeping = false;

  set pageMetrics(ValueListenable<ScrollMetrics?> value) {
    if (identical(value, _pageMetrics)) return;
    if (attached) {
      _pageMetrics.removeListener(_onPageMoved);
      value.addListener(_onPageMoved);
    }
    _pageMetrics = value;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _pageMetrics.addListener(_onPageMoved);
  }

  @override
  void detach() {
    _pageMetrics.removeListener(_onPageMoved);
    super.detach();
  }

  void _onPageMoved() {
    if (!_keeping) return;
    // A page's scroll activity can change during layout, when its content has
    // changed, and that can't lay anything out again until the frame is over.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (attached) markNeedsLayout();
      });
    } else {
      markNeedsLayout();
    }
  }

  /// How much of [extra] can go without moving the page.
  double _mayGiveBack(double extra) {
    final page = _pageMetrics.value;
    if (page == null || page.pixels <= page.minScrollExtent) return extra;
    return math.min(extra, page.extentAfter);
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      _keeping = false;
      return;
    }
    child.layout(constraints.copyWith(minHeight: 0), parentUsesSize: true);
    final natural = child.size.height;
    final extra = hasSize ? math.max(0.0, size.height - natural) : 0.0;
    final height = constraints.constrainHeight(
      natural + extra - _mayGiveBack(extra),
    );
    _keeping = height > natural;
    size = constraints.constrain(Size(child.size.width, height));
    // At the foot of the band, so what is left of the footer stays put.
    (child.parentData! as BoxParentData).offset = Offset(0, height - natural);
  }
}
