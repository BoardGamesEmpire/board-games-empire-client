import 'package:flutter/foundation.dart'
    show clampDouble, precisionErrorTolerance;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderSliverMultiBoxAdaptor, ScrollDirection;
import 'package:flutter/services.dart' show HardwareKeyboard, KeyUpEvent;
import 'package:ui_tokens/ui_tokens.dart';

import 'banner_action_layout.dart';

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
  ///
  /// It sits beside the message while the message's text keeps at least
  /// [minMessageWidthEms] ems of width, and below it, at the end edge,
  /// otherwise.
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

  /// The narrowest the message's text may get beside an [action], in ems of
  /// the body text's scaled font size. Below it the action moves under the
  /// message (#452).
  ///
  /// In ems so that it scales with the text. A threshold in dp holds half as
  /// many characters at 200% text scale as it does at 100%: the 140dp that is
  /// ten ems at 1.0 is only five at 2.0. A rule that stacks only when the
  /// message gets less than half the banner ignores text scale as well. At
  /// 412dp and 2.0 the message gets about half and the action stays beside,
  /// and #452 measured that half as a 135dp column nine lines tall.
  ///
  /// Ten ems is 140dp of text at 1.0 and 280dp at 2.0. By #452's real-font
  /// measurements, that keeps a retry button beside the message at 412dp and
  /// 1.0, and stacks it at 320 and 360dp at 1.0 and at every phone width at
  /// 2.0.
  static const double minMessageWidthEms = 10;

  @override
  State<BgeInlineBanner> createState() => _BgeInlineBannerState();
}

class _BgeInlineBannerState extends State<BgeInlineBanner> {
  /// The position a deferred reveal is waiting on, if any.
  ///
  /// Held so the listener can be removed: a reveal skipped during a gesture is
  /// queued, not discarded, and the queue has to be cancellable.
  ScrollPosition? _awaitingIdleOn;

  /// The position a reveal is animating on, or was cut short on, while this
  /// banner watches it: for the user scrolling it from the moment the
  /// animation starts, and once the animation is found cut short, for the
  /// interaction that did it to end.
  ///
  /// Held for the same reason as [_awaitingIdleOn]: the watch has to be
  /// cancellable when the banner goes away or stops being an outcome.
  ScrollPosition? _watchedOn;

  /// The reveal being watched on [_watchedOn]. An animation's completion acts
  /// only while its own reveal is still this one.
  Object? _watchedReveal;

  /// Whether the user has scrolled [_watchedOn], or pressed a key, since the
  /// watched reveal started — the one thing that turns a retry into fighting
  /// them (#233).
  bool _userScrolledSinceReveal = false;

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
      // widget's life. A retry waiting on an interrupted reveal is the same
      // kind of queued work.
      _stopAwaitingIdle();
      _stopWatchingReveal();
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
    // A post-frame callback does not ask for the frame it waits on. From
    // `initState` and `didUpdateWidget` there is always one coming — they run
    // inside it, and this is a no-op there. Two callers run outside any
    // build. A retry comes from the post-frame check that settles the
    // interaction that cut a reveal short (#233), and nothing else asks for
    // the frame after it: measured without the request, the retry never ran
    // after a jump or a long press, and the banner stayed wherever the
    // interruption left it. The other is the deferral's `_onScrollingChanged`,
    // which re-attempts when a gesture ends. It is a notifier's listener,
    // called from outside a build (at pointer-up, for one), so it gets the
    // same request rather than waiting on whatever draws next.
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _revealNow() {
    // `reveal` is re-read rather than trusted from schedule time: the flag can
    // be state-derived, and a rebuild between the two would otherwise still
    // scroll for a banner the caller has since declared persistent.
    if (!mounted || !widget.reveal) return;

    // A fresh attempt replaces any reveal before it. The branch that animates
    // releases the old watch itself, in `_startWatchingReveal`. This is for
    // the branches below that don't animate. A watch from an earlier reveal
    // does not outlive the attempt that replaced it, and an earlier animation
    // still in flight is disowned with it: if it is cut short later, its
    // completion finds no current reveal and arms nothing (#233).
    _stopWatchingReveal();

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
    // bottom edge "visible" — which is the shape `BgeFormActions` produces,
    // since its banner lands in the space the submit button occupied.
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

    // Released immediately BEFORE the scroll, not after it lands, and the
    // ordering is forced rather than incidental: `animateTo` begins a
    // DrivenScrollActivity, whose `isScrolling` flips `isScrollingNotifier`.
    // A listener still attached would therefore fire on this widget's own
    // animation and re-enter — past the gesture guard, because `animateTo`
    // never touches `userScrollDirection` (it only calls `beginActivity`), so
    // a programmatic scroll still reads as idle. The re-entry starts a second
    // animateTo that interrupts the first. Measured: two competing animations
    // for one reveal, the first reporting that it never reached its target.
    //
    // An animation cut short is retried instead from its returned future
    // (#233), and the `isScrollingNotifier` listener stays detached while it
    // runs. The only thing attached during the animation is a latch on the
    // position's moves. It reads the scroll direction into a flag and never
    // re-enters this method, and this widget's own animation leaves the
    // direction idle, so the ordering above still holds.
    //
    // Anything that begins a new scroll activity on this position disposes
    // the DrivenScrollActivity, and a bare TAP is enough: the drag
    // recognizer's `onDown` fires on pointer-down, before arena resolution
    // and before any movement (monodrag.dart `_addPointer`), and calls
    // `position.hold()`. Measured before the retry existed: a tap 4ms in froze
    // the scroll at 354 of a 1184 target and left the banner 845dp down a
    // 480dp viewport, off screen, with nothing queued. Tapping a field, or the
    // submit button a second time, is enough. See [_afterReveal] for how a tap
    // is told apart from a drag, which must not be retried.
    _stopAwaitingIdle();

    // The zero-duration branch is not decoration: `animateTo` builds a
    // DrivenScrollActivity whatever the duration, so under OS reduced motion it
    // would still take a frame to arrive rather than being complete instantly.
    // `ScrollPosition.ensureVisible` splits the same way for the same reason.
    if (duration == Duration.zero) {
      position.jumpTo(target);
    } else {
      final reveal = _startWatchingReveal(position);
      position
          .animateTo(target, duration: duration, curve: BgeMotion.enter)
          .then((_) => _afterReveal(position, target, reveal));
    }
  }

  /// Starts watching [position] for the user scrolling it, ahead of a reveal
  /// animation on it, and returns the identity of that reveal.
  Object _startWatchingReveal(ScrollPosition position) {
    _stopWatchingReveal();
    _watchedOn = position;
    // Latched from the start of the animation rather than from the moment it
    // is found cut short. A mouse-wheel tick sets the direction, moves the
    // page, goes idle and drops the direction again inside one event, before
    // the animation's future has even completed. A watch that began only then
    // read a wheel scroll as a tap and retried over it, undoing the user's
    // scroll on desktop and web.
    position.addListener(_onWatchedMove);
    // A key pressed while the reveal runs is the user as well, and the
    // scroll it makes leaves the direction idle. PageDown and the arrow keys
    // scroll through `ScrollAction`, which calls `moveTo`. Tab moves focus,
    // and the newly focused field is scrolled into view with
    // `ensureVisible`. To the position both are programmatic scrolls, the
    // same as the scroll that follows a tap on a field, which is retried.
    // Without the key, a retry took a keyboard user back to the banner, away
    // from where they had scrolled or tabbed to.
    HardwareKeyboard.instance.addHandler(_onWatchedKey);
    return _watchedReveal = Object();
  }

  void _onWatchedMove() {
    final position = _watchedOn;
    if (position != null &&
        position.userScrollDirection != ScrollDirection.idle) {
      _userScrolledSinceReveal = true;
    }
  }

  bool _onWatchedKey(KeyEvent event) {
    // Not a release: the key that submitted the form can come up after the
    // reveal has started.
    if (event is! KeyUpEvent) _userScrolledSinceReveal = true;
    // Watched, never handled: the key still goes on to whatever it does.
    return false;
  }

  /// Runs when a reveal's animation ends, whether it arrived or was cut short.
  void _afterReveal(ScrollPosition position, double target, Object reveal) {
    // Superseded or released: a newer attempt started, or the banner went
    // away or stopped being an outcome. Only the current reveal's completion
    // may act on the watch. A superseded animation's shortfall is the
    // widget's own doing, not an interaction, and without this check it would
    // act on whatever watch is current: arming the newer reveal's settle
    // check while that reveal still animates, or releasing it outright if the
    // banner had moved to another scroll view. A defence rather than a fix:
    // measured with it removed, no case in the suite changes outcome, because
    // the settle check's one-frame wait already absorbs an early arm.
    if (!identical(reveal, _watchedReveal)) return;

    // Each of these settles the reveal: the banner went away or stopped being
    // an outcome, the page it was revealed in is no longer its page, or the
    // animation arrived.
    if (!mounted ||
        !widget.reveal ||
        Scrollable.maybeOf(context, axis: Axis.vertical)?.position !=
            position ||
        (position.pixels - target).abs() <= precisionErrorTolerance) {
      _stopWatchingReveal();
      return;
    }

    // Cut short, and the question is by what (#233). A drag, a wheel or a key
    // is the user deliberately going elsewhere and must be left alone; a tap, a
    // long press or a programmatic scroll (focusing a field) means nothing of
    // the kind, and leaving the banner wherever the animation froze is #209's
    // failure reached through the reveal itself.
    //
    // The answer is not known yet. The future completes at POINTER-DOWN —
    // the hold that disposes the animation is the drag recognizer's `onDown`
    // — before the finger has moved, so here a tap, a long press and the
    // start of a drag all read as idle. Retrying now would take the page
    // back from a user who is just beginning to drag it. So the decision
    // waits for the interaction to end, and the latch keeps running through
    // it: a direction seen at ANY point since the animation started marks the
    // user scrolling.
    _watchInterruption(position);
  }

  void _watchInterruption(ScrollPosition position) {
    // Removed before it is added: `ChangeNotifier` keeps duplicate listeners
    // and removal takes only one of each, so a second report for the same
    // watch would otherwise leak one.
    position.isScrollingNotifier
      ..removeListener(_onInterruptionScrollingChanged)
      ..addListener(_onInterruptionScrollingChanged);

    // An interruption that was over before this ran never notifies again: a
    // `jumpTo` disposes the animation and ends in the same call, and the
    // future only completes a microtask later. So it is checked once after
    // the next frame. That frame needs no asking for: the animation being
    // interrupted had already requested it for its next tick, and the request
    // outlives the animation. Measured, a frame is pending at the moment of
    // the interruption even for a tap whose down and up arrive together.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _onInterruptionScrollingChanged(),
    );
  }

  void _onInterruptionScrollingChanged() {
    final position = _watchedOn;
    // A touch on a page whose reveal was animating reaches only the scroll
    // view's drag recognizer — the animation ignores pointers, so no field or
    // button competes — and the arena hands it the pointer a microtask after
    // it lands. So the position reads as scrolling until the finger lifts,
    // whether or not it moved, except for one instant at pointer-down: the
    // `hold()` that stops the scroll comes before the drag starts, and reads
    // as not scrolling. False here is the interaction ending, or that instant.
    if (position == null || position.isScrollingNotifier.value) return;

    // The latch sees the user only when the page moves, and a drag into the
    // edge the page already rests on is overscroll: the page never moves. So
    // the direction is read here too, and folded into the latch. It still
    // holds the drag's direction at this point because
    // `ScrollPosition.beginActivity` sets `isScrollingNotifier` before
    // `ScrollPositionWithSingleContext` resets the direction to idle. If that
    // ordering ever changes, this read finds idle and the check degrades to
    // the latch alone. Read now, not when the decision below is made: by the
    // next frame the reset has happened. Measured reading it there, the drag
    // into the edge was retried again.
    if (position.userScrollDirection != ScrollDirection.idle) {
      _userScrolledSinceReveal = true;
    }

    // The decision waits a frame, to tell the two apart: by then a drag has
    // taken over from the hold, and the page reads as scrolling again.
    // Decided on the spot, a touch during a programmatic scroll that had cut
    // the reveal short read as settled, and the retry started under the
    // finger and took the page out from under it. The frame is asked for:
    // from a finger lifting, or from the settle check after a jump, nothing
    // else need be coming. Measured without the request, the jump case never
    // settled.
    //
    // The limit that remains: a hold the arena has NOT resolved, because
    // another recognizer such as a field's tap is still competing for the
    // pointer, reads as not scrolling at the frame as well. Telling it from a
    // page at rest takes the position's `activity`, which is protected, so a
    // touch caught in that window still reads as settled.
    WidgetsBinding.instance.addPostFrameCallback((_) => _settleInterruption());
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _settleInterruption() {
    final position = _watchedOn;
    // The watch ended in the meantime, or the page is scrolling again — the
    // touch became a drag — and the watch goes on to the next time it stops.
    if (position == null || position.isScrollingNotifier.value) return;

    final userScrolled = _userScrolledSinceReveal;
    // Detached before the retry starts, for the reason the deferral is
    // released before a scroll: the retry's own animation would flip
    // `isScrollingNotifier` and re-enter the watch.
    _stopWatchingReveal();
    // Through the scheduler, so `_revealNow` re-checks visibility and the
    // gesture guard on settled geometry: a banner the interruption happened
    // to leave readable is not moved again.
    if (!userScrolled) _scheduleReveal();
  }

  void _stopWatchingReveal() {
    if (_watchedOn != null) {
      HardwareKeyboard.instance.removeHandler(_onWatchedKey);
    }
    _watchedOn?.removeListener(_onWatchedMove);
    _watchedOn?.isScrollingNotifier.removeListener(
      _onInterruptionScrollingChanged,
    );
    _watchedOn = null;
    _watchedReveal = null;
    _userScrolledSinceReveal = false;
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
    _stopWatchingReveal();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final (background, foreground, icon) = _resolve(theme.colorScheme);

    // Shared by the message row and the threshold that keeps it readable
    // beside an [action], so that resizing the icon, its gap or the text
    // moves the threshold with it.
    final iconSize = tokens.spaceLg;
    const iconGap = BgeGap.md(axis: Axis.horizontal);
    final bodyStyle = theme.textTheme.bodyMedium;

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
            Icon(icon, color: foreground, size: iconSize),
            iconGap,
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
                    style: bodyStyle?.copyWith(color: foreground),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    final action = widget.action;
    final body = action == null
        ? message
        : BannerActionLayout(
            message: message,
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
            action: TextButtonTheme(
              data: TextButtonThemeData(
                style: TextButton.styleFrom(foregroundColor: foreground),
              ),
              child: IconButtonTheme(
                data: IconButtonThemeData(
                  style: IconButton.styleFrom(foregroundColor: foreground),
                ),
                child: IconTheme.merge(
                  data: IconThemeData(color: foreground),
                  child: action,
                ),
              ),
            ),
            gap: tokens.spaceSm,
            // The message slot holds the icon and its gap as well as the
            // text, so the minimum counts them too. The text's share is in
            // ems of the body text at the size it is drawn, which is scaled.
            // `BgeTheme` always sets that size. A theme that leaves it unset
            // draws the text at Flutter's default of 14, which is the role's
            // token size, so the token stands in for it.
            minMessageWidth:
                iconSize +
                iconGap.extentOf(context) +
                BgeInlineBanner.minMessageWidthEms *
                    MediaQuery.textScalerOf(context)
                        .scale(bodyStyle?.fontSize ?? BgeTypography.bodyMedium),
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
