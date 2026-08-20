import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderSliverMultiBoxAdaptor, ScrollDirection;
import 'package:ui_tokens/ui_tokens.dart';

/// The tone of a [BgeInlineBanner], which selects its color pair and icon.
enum BgeBannerTone {
  /// Something failed and the user needs to know. Uses the error roles.
  error,

  /// Neutral context or explanation.
  info,

  /// Something needs attention but nothing has failed.
  ///
  /// Uses the ember (tertiary) roles. Deliberately distinct from [error] in
  /// hue — the palette holds those ~54° apart precisely so a warning does not
  /// read as a failure. See `BgeColorSchemes`.
  warning,

  /// An action succeeded.
  success,
}

/// An inline message block: a tinted, rounded container with an icon, an
/// optional title, and a message (#165).
///
/// ```dart
/// BgeInlineBanner(
///   tone: BgeBannerTone.error,
///   title: l10n.serverAddErrorTitle,
///   message: failureMessage,
/// )
/// ```
///
/// Replaces three hand-rolled banners that had drifted apart — radius 8 in one
/// place and 12 in another, different padding in each, and one setting a raw
/// `TextStyle(color:)` instead of taking a role from the text theme.
///
/// ## Accessibility
///
/// - The whole banner is a **live region** by default ([announce]), so
///   assistive tech reads it when it appears rather than waiting for the user
///   to navigate onto it. Call sites previously had to remember to wrap this
///   themselves, and inconsistently did.
/// - It merges into **one** semantics node: a screen reader gets "error:
///   this URL is not a BGE server", not a decorative icon followed by two
///   fragments.
/// - **It scrolls itself into view** on appearance ([reveal]), leading with its
///   **top** edge. The live region alone left a sighted user with a submit
///   button that appeared to do nothing while the banner sat outside the
///   viewport (#209). The top edge rather than the whole banner because at 200%
///   text scale a single error string can be taller than the viewport, and a
///   centred reveal would show the middle of a wrapped sentence. Skipped when
///   the banner is already readable where it stands, so it never moves a
///   viewport that was fine.
///
///   Unlike the live region, this is **not** unconditional — it acts on the
///   nearest enclosing vertical scroll view, and does nothing without one.
///   See [reveal].
/// - **The icon is not decorative.** Tone here is conveyed by color *and*
///   icon, which is the project's stated answer to color-vision deficiency.
///   A banner that signalled failure by being red alone would be unusable for
///   the users most likely to be reading an error message carefully.
class BgeInlineBanner extends StatefulWidget {
  /// Creates an inline banner.
  const BgeInlineBanner({
    required this.message,
    this.tone = BgeBannerTone.info,
    this.title,
    this.action,
    this.announce = true,
    this.reveal = true,
    super.key,
  });

  /// The body text. Already localized — this package takes strings, not keys.
  final String message;

  /// Which color pair and icon to use.
  final BgeBannerTone tone;

  /// Optional bolder heading above [message].
  final String? title;

  /// Optional trailing action, e.g. a retry button.
  final Widget? action;

  /// Whether the banner announces itself on appearance. Leave true unless the
  /// surrounding screen already announces the same information.
  final bool announce;

  /// Whether the banner scrolls itself into view on appearance, and again
  /// whenever its copy changes.
  ///
  /// Leave true for an outcome. Set false for a **persistent** banner — an
  /// offline indicator is furniture rather than news, and one that scrolls
  /// itself into view on every mount fights a restored scroll position.
  ///
  /// A banner built **lazily inside a list** does not need the flag: a row is
  /// never treated as an arriving outcome, whatever this is set to. Relying on
  /// the flag there would mean a forgotten one makes the list unusable rather
  /// than merely unhelpful, so it is detected instead.
  ///
  /// **Precondition.** The reveal acts on the **nearest enclosing vertical
  /// scroll view**, and needs laid-out geometry. Without one it is a silent
  /// no-op — the banner still announces, but nothing scrolls it into view.
  ///
  /// It does not walk outward through *nested* vertical scroll views the way
  /// `Scrollable.ensureVisible` does, so a banner inside an inner vertical
  /// scroller can be revealed within that scroller while the scroller itself
  /// sits off screen in the page. No surface here nests vertical scroll views —
  /// that is what [BgePage.slivers] exists to avoid — but a call site that
  /// introduces one owns keeping the outer page in the right place.
  ///
  /// This is the one guarantee on this widget that depends on its host.
  final bool reveal;

  @override
  State<BgeInlineBanner> createState() => _BgeInlineBannerState();
}

class _BgeInlineBannerState extends State<BgeInlineBanner> {
  /// The position a deferred reveal is waiting on, if any.
  ///
  /// Held so the listener can be removed: a reveal skipped during a gesture is
  /// queued, not discarded, and the queue has to be cancellable.
  ScrollPosition? _awaitingIdleOn;

  @override
  void initState() {
    super.initState();
    _scheduleReveal();
  }

  @override
  void didUpdateWidget(BgeInlineBanner oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (!widget.reveal) {
      // Turned off. Cancel queued work: a banner that has become persistent
      // must not act on a reveal it was scheduled for while it was still an
      // outcome, and leaving the listener attached would hold it for the
      // widget's life.
      _stopAwaitingIdle();
      return;
    }

    // Copy changed under a banner that stayed mounted — a second failure with
    // no edit between. The live region re-announces on exactly this change, so
    // a screen-reader user hears the new message; revealing only on first
    // insertion would leave the sighted user with the stale view.
    //
    // `action` is not on this list: swapping a retry button is not new copy.
    final copyChanged =
        oldWidget.message != widget.message ||
        oldWidget.title != widget.title ||
        oldWidget.tone != widget.tone;

    // `reveal` turning on is itself an appearance — the banner has just become
    // an outcome. Copy is unchanged across such a flip, so the copy path
    // cannot cover it and nothing else would ever schedule the reveal.
    if (copyChanged || !oldWidget.reveal) _scheduleReveal();
  }

  void _scheduleReveal() {
    if (!widget.reveal) return;
    // Post-frame: the reveal needs this banner's laid-out geometry, and on the
    // frame it is inserted there is none yet.
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealNow());
  }

  void _revealNow() {
    // `reveal` is re-read rather than trusted from schedule time: the flag can
    // be state-derived, and a rebuild between the two would otherwise still
    // scroll for a banner the caller has since declared persistent.
    if (!mounted || !widget.reveal) return;

    // **Vertical** explicitly. `Scrollable.maybeOf` otherwise returns the
    // nearest scrollable on ANY axis, and the `.dy` reading below against a
    // horizontal viewport is meaningless — a banner inside a horizontal strip
    // would measure as visible and veto the reveal on the page that has to
    // move.
    //
    // Null is a supported arrangement, not a mistake to assert on: the golden
    // suite renders the banner bare, and a call site may host it outside a
    // scroll view. See [reveal] for what that costs.
    final scrollable = Scrollable.maybeOf(context, axis: Axis.vertical);
    if (scrollable == null) return;
    final position = scrollable.position;

    // Never fight a scroll the USER is driving (#209: "care not to fight a
    // user who has deliberately scrolled elsewhere"). Without this, a banner
    // realized inside a lazily-built list asks for the viewport on every newly
    // built row and pins the drag in place.
    //
    // Deferred, not dropped. A submit's failure can land while the user is
    // flicking the page, and returning outright left the banner off screen
    // until some later copy change — the guarantee lapsing silently, which is
    // the whole defect. The queued attempt re-runs the visibility check when
    // the gesture ends, so a user who happened to scroll to it is left alone.
    //
    // `userScrollDirection` rather than `isScrollingNotifier`, which is true
    // for programmatic scrolls too: focusing a field scrolls it into view, so
    // gating on any scroll at all meant a banner arriving just after the user
    // typed was never revealed — the primary case this widget exists for.
    if (position.userScrollDirection != ScrollDirection.idle) {
      _deferUntilIdle(position);
      return;
    }

    // The queue is NOT released here. Every return below this point leaves the
    // banner unrevealed, and releasing on the way past them dropped a deferred
    // reveal permanently: an attempt that re-ran when a fling settled, then
    // bailed on geometry, detached its listener and was never re-triggered —
    // `didUpdateWidget` reschedules only on a copy change or a `reveal`
    // false-to-true flip, and an unchanged error message is neither. That is
    // the #209 failure mode arriving by a different route. Released instead at
    // the two points that actually settle the question: an accomplished reveal,
    // and the already-visible check that makes one unnecessary.
    final self = context.findRenderObject();
    final viewport = scrollable.context.findRenderObject();
    if (self is! RenderBox ||
        viewport is! RenderBox ||
        !self.hasSize ||
        !viewport.hasSize) {
      return;
    }

    // Breathing room above a revealed banner. `BgePage` puts its content
    // inset inside the scroll view, so aligning the banner's top exactly to
    // the viewport start scrolls that inset away and leaves the banner flush
    // against the app bar — or the safe-area edge on a screen with no app bar,
    // like auth. That reads as a clipped banner rather than a revealed one.
    // A banner built lazily as a **list row** is not an arriving outcome, and
    // must not ask for the viewport: every row realized during a scroll would
    // demand it, and the demands cascade. Measured, a `ListView.builder` with a
    // banner every fifth row ran away to offset 23384 on first layout and
    // could not be scrolled back.
    //
    // Detected structurally rather than left to `reveal: false`, because a
    // forgotten flag there makes the list unusable rather than merely
    // unhelpful — and from inside a leaf widget a lazily realized row and a
    // freshly arrived outcome are otherwise indistinguishable. A banner placed
    // as its own sliver (`SliverToBoxAdapter`) has no adaptor between it and
    // the viewport, so it still reveals.
    for (
      RenderObject? node = self;
      node != null && node != viewport;
      node = node.parent
    ) {
      if (node is RenderSliverMultiBoxAdaptor) {
        // Releases the queue: being a lazily-built row is structural, so no
        // later idle transition changes the answer. Holding the listener would
        // pin it for the widget's life and re-run this walk on every scroll.
        _stopAwaitingIdle();
        return;
      }
    }

    final tokens = BgeTokens.of(context);
    final inset = tokens.spaceMd;

    // Measured in the viewport's own space: positive means below its top edge.
    final top = self.localToGlobal(Offset.zero, ancestor: viewport).dy;

    // Already readable where it stands, in one of two ways: the whole banner
    // is on screen, or it is taller than the viewport and already starts at
    // the top. Testing the top edge alone would call a 10dp sliver above the
    // bottom edge "visible" — which is the shape ServerAddForm produces, since
    // its banner lands in the space the submit button occupied.
    final endsOnScreen = top + self.size.height <= viewport.size.height;
    if (top >= 0 && (endsOnScreen || top <= inset)) {
      // Releases the queue: the banner is readable where it stands, which is
      // the outcome the deferral was waiting for. This is the "user scrolled to
      // it themselves during the fling" case — satisfied, not abandoned.
      _stopAwaitingIdle();
      return;
    }

    // Computed rather than delegated to `Scrollable.ensureVisible`, for two
    // reasons. It reveals flush against the viewport edge with no way to keep
    // the inset above; and its `alignmentPolicy` choices are each wrong here —
    // `keepVisibleAtStart` is a no-op for a banner entirely BELOW the viewport
    // (reachable when a form submits from a field's keyboard action rather
    // than a button the user scrolled to), while the default `explicit` policy
    // moves a viewport that was already fine. The visibility check above
    // covers both directions instead.
    // Signed, because the conversion from a viewport coordinate to a scroll
    // offset depends on which way the axis runs. Under AxisDirection.up —
    // a `reverse: true` scroll view — increasing `pixels` moves content the
    // other way, so adding the delta sends an above-viewport banner to a
    // negative target, which clamps at the minimum extent and leaves it
    // hidden. No surface here scrolls in reverse today; the widget is shared.
    final delta = top - inset;
    final target = clampDouble(
      position.axisDirection == AxisDirection.up
          ? position.pixels - delta
          : position.pixels + delta,
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final duration = BgeMotion.durationOf(context, tokens.motionShort);

    // Released on the accomplished reveal, immediately before it happens —
    // the guarantee this widget makes is now met.
    _stopAwaitingIdle();

    // The zero-duration branch is not decoration: `animateTo` builds a
    // DrivenScrollActivity whatever the duration, so under OS reduced motion it
    // would still take a frame to arrive rather than being complete instantly.
    // `ScrollPosition.ensureVisible` splits the same way for the same reason.
    if (duration == Duration.zero) {
      position.jumpTo(target);
    } else {
      position.animateTo(target, duration: duration, curve: BgeMotion.enter);
    }
  }

  void _deferUntilIdle(ScrollPosition position) {
    if (_awaitingIdleOn == position) return;
    _stopAwaitingIdle();
    _awaitingIdleOn = position;
    position.isScrollingNotifier.addListener(_onScrollingChanged);
  }

  void _onScrollingChanged() {
    if (_awaitingIdleOn == null) return;
    // Re-attempt rather than deciding here. `_revealNow` already re-reads the
    // scroll direction and re-defers if the gesture is still running — the
    // ballistic tail of a fling is part of it — so this needs no notion of
    // "is it over yet" of its own, and there is no branch here that the
    // deferral tests cannot reach. The listener stays attached until the reveal
    // is either accomplished or settled as unnecessary — never merely because
    // an attempt was made — so a transition cannot slip through the gap between
    // detaching and re-attaching, and an attempt that bails on geometry stays
    // queued for the next one.
    //
    // Back through the scheduler rather than revealing inline: this fires from
    // a notifier mid-frame, and the reveal needs settled geometry.
    _scheduleReveal();
  }

  void _stopAwaitingIdle() {
    _awaitingIdleOn?.isScrollingNotifier.removeListener(_onScrollingChanged);
    _awaitingIdleOn = null;
  }

  @override
  void dispose() {
    _stopAwaitingIdle();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final (background, foreground, icon) = _resolve(theme.colorScheme);

    // The merge and the live region cover the ICON + TEXT only. [action] is
    // deliberately outside both: merging a button into the banner's node
    // strips its own semantics — a retry control stops being separately
    // focusable and activatable, and a screen-reader user gets one long
    // unactionable string where there was an error and a way out of it.
    // `UnverifiedSessionBanner` scopes it the same way, with its dismiss
    // IconButton outside the merged region.
    final message = MergeSemantics(
      child: Semantics(
        liveRegion: widget.announce,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: foreground, size: tokens.spaceLg),
            const BgeGap.md(axis: Axis.horizontal),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.title != null) ...[
                    Text(
                      widget.title!,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: foreground,
                      ),
                    ),
                    const BgeGap.xs(),
                  ],
                  Text(
                    widget.message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    final body = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: message),
        if (widget.action != null) ...[
          const BgeGap.sm(axis: Axis.horizontal),
          // The action inherits the banner's foreground rather than the
          // ambient one. A plain `TextButton` defaults to `colorScheme
          // .primary`, which is electric blue — 2.92:1 against the dark
          // error container, and it fails the same way on every toned
          // container because each is a saturated mid-dark surface the
          // accent was never solved against.
          //
          // Applied as a theme rather than a required parameter so callers
          // keep passing an ordinary button: making legibility opt-in is how
          // it gets missed.
          TextButtonTheme(
            data: TextButtonThemeData(
              style: TextButton.styleFrom(foregroundColor: foreground),
            ),
            child: IconButtonTheme(
              data: IconButtonThemeData(
                style: IconButton.styleFrom(foregroundColor: foreground),
              ),
              child: IconTheme.merge(
                data: IconThemeData(color: foreground),
                child: widget.action!,
              ),
            ),
          ),
        ],
      ],
    );

    return Container(
      padding: EdgeInsets.all(tokens.spaceMd),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(tokens.radiusMd),
      ),
      child: body,
    );
  }

  (Color background, Color foreground, IconData icon) _resolve(
    ColorScheme scheme,
  ) => switch (widget.tone) {
    BgeBannerTone.error => (
      scheme.errorContainer,
      scheme.onErrorContainer,
      Icons.error_outline,
    ),
    BgeBannerTone.info => (
      scheme.secondaryContainer,
      scheme.onSecondaryContainer,
      Icons.info_outline,
    ),
    BgeBannerTone.warning => (
      scheme.tertiaryContainer,
      scheme.onTertiaryContainer,
      Icons.warning_amber_outlined,
    ),
    BgeBannerTone.success => (
      scheme.primaryContainer,
      scheme.onPrimaryContainer,
      Icons.check_circle_outline,
    ),
  };
}
