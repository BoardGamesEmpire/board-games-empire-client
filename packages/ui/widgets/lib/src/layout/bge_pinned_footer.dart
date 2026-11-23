import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show BoxParentData, PipelineOwner, RenderShiftedBox;
import 'package:flutter/scheduler.dart' show SchedulerBinding, SchedulerPhase;

/// A scrolling body over a footer pinned under it, whose footer can change
/// height without moving the body's rows.
///
/// `BgePage` builds its `footer:` on this. So does a pop-up that pins an
/// action under its own scroll view, where there is no page: the catalog's
/// quick look, whose Import counts the expansions ticked (#1037). It was
/// `BgePage`'s own until that second caller.
///
/// It lays [body] out over [footer], and holds the pair to the rules below.
/// It builds one tree whatever the footer draws, so pass a footer on every
/// build, one that draws nothing while there is nothing to pin: a caller
/// that built this only while it had a footer would lose the body's scroll
/// position and focus as the footer came and went (#457).
///
/// ## The footer takes at most half
///
/// The footer is outside the body's scroll view, so an unbounded one starves
/// the body: a tall footer at 200% text scale drove a page's scroll view to
/// zero height and made the whole page unreachable. So the footer is held to
/// [maxFooterFraction] of the height on offer, which leaves the body at
/// least half.
///
/// The cap bounds the footer; it doesn't size it. Pass a footer that scrolls
/// when it is taller than the cap, a scroll view that shrink-wraps, or the
/// cap only trades one unreachable region for another.
///
/// ## It keeps the room a shorter footer gives back
///
/// The body's view gets taller by what a shorter footer gives back, so the
/// end of the body comes up to meet it. With the body scrolled to its end,
/// that would drop every row by that height, under a pointer that may be
/// about to press one. So the footer's band gives back only what the body
/// has left below its view, and keeps the rest as empty room above what is
/// left of the footer. That room goes as the body leaves its end, at the
/// pace it leaves. A body at its start has nothing to drop, and takes it
/// all at once (#457).
///
/// A footer that gets taller takes its room from the foot of the view, and
/// moves no row either: the body keeps its scroll position. It takes up
/// what the band kept first.
///
/// The band hears where the body is from the scroll notifications of the
/// body's own scroll view, the outermost in [body]. One inside it, or a
/// horizontal strip on it, says nothing about where the body is.
///
/// ## What a pop-up changes
///
/// A page fills its window, and its footer's insets are the page's own
/// padding. A pop-up is as tall as its content, and its footer may empty
/// for good:
///
/// - [shrinkWrap] lets the pair take only the height they need.
/// - [footerPadding] insets the footer, and goes with a footer that draws
///   nothing, so no strip is left where it was.
/// - [emptiedFooterKeepsRoom], set false, gives back at once all the room of
///   a footer that has come to draw nothing.
class BgePinnedFooter extends StatefulWidget {
  /// Lays [body] out over [footer], pinned under it.
  const BgePinnedFooter({
    required this.body,
    required this.footer,
    this.shrinkWrap = false,
    this.footerPadding = EdgeInsets.zero,
    this.emptiedFooterKeepsRoom = true,
    this.footerKey,
    super.key,
  });

  /// The largest share of the height on offer the footer may take.
  ///
  /// Named rather than written inline: it is a proportion, not a spacing or
  /// width decision, so there is no token for it, but an unexplained `/ 2`
  /// in a constraint reads like one.
  static const double maxFooterFraction = 0.5;

  /// What scrolls: the caller's own scroll view, and whatever it puts
  /// around it.
  final Widget body;

  /// What is pinned under [body]. One that draws nothing has no height.
  final Widget footer;

  /// Whether the pair take only the height they need, as a pop-up sized to
  /// its content does. False, the default, fills the height on offer, as a
  /// page does: the body takes all that the footer leaves.
  final bool shrinkWrap;

  /// Insets around the footer, inside its band. They are the footer's: one
  /// with no height takes none of them, so a footer that draws nothing
  /// leaves no strip behind.
  ///
  /// They stay put while a footer taller than its cap scrolls within them.
  /// A page passes none: its footer's insets are the page's padding, there
  /// whether or not the footer draws anything.
  final EdgeInsets footerPadding;

  /// Whether a footer that has come to draw nothing keeps its room as one
  /// that got shorter does.
  ///
  /// True, the default, for a body whose rows stay as its footer empties: a
  /// page's list, when the banner in its footer is dismissed.
  ///
  /// False where the footer empties only as the body is redrawn. A quick
  /// look's footer empties when its import starts, and the progress takes
  /// the checklist's place in the body: no row is left to hold still, and
  /// the room kept would be an empty strip where the button was. A footer
  /// that gets shorter and still draws something keeps its room either way.
  final bool emptiedFooterKeepsRoom;

  /// A key for the footer's band: the box under [body] that holds the
  /// footer, its insets and any room kept for it.
  final Key? footerKey;

  @override
  State<BgePinnedFooter> createState() => _BgePinnedFooterState();
}

class _BgePinnedFooterState extends State<BgePinnedFooter> {
  /// How the body's own scroll view last reported itself. Null until it has.
  final ValueNotifier<ScrollMetrics?> _bodyMetrics = ValueNotifier(null);

  @override
  void dispose() {
    _bodyMetrics.dispose();
    super.dispose();
  }

  bool _onBodyNotification(Notification notification) {
    final (metrics, depth) = switch (notification) {
      ScrollNotification(:final metrics, :final depth) => (metrics, depth),
      ScrollMetricsNotification(:final metrics, :final depth) => (
        metrics,
        depth,
      ),
      _ => (null, 0),
    };
    // Only the body's own: a horizontal strip on it, or a scroll view inside
    // it, says nothing about where the body is.
    if (metrics != null && depth == 0) _bodyMetrics.value = metrics;
    return false;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final body = NotificationListener<Notification>(
        onNotification: _onBodyNotification,
        child: widget.body,
      );
      return Column(
        mainAxisSize: widget.shrinkWrap ? MainAxisSize.min : MainAxisSize.max,
        // Stretch so the footer's own cap decides its width. Left to
        // shrink-wrap it would centre at its intrinsic width and stop lining
        // up with the column above it.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.shrinkWrap)
            Flexible(child: body)
          else
            Expanded(child: body),
          ConstrainedBox(
            key: widget.footerKey,
            // The footer is not in the scroll view, so an unbounded one
            // starves the body above it: see "The footer takes at most
            // half".
            constraints: BoxConstraints(
              maxHeight:
                  constraints.maxHeight * BgePinnedFooter.maxFooterFraction,
            ),
            child: _FooterRoom(
              bodyMetrics: _bodyMetrics,
              padding: widget.footerPadding,
              emptiedKeepsRoom: widget.emptiedFooterKeepsRoom,
              child: widget.footer,
            ),
          ),
        ],
      );
    },
  );
}

/// The footer's band: the footer in its insets, and above it the room a
/// shorter footer would give back, kept while giving it back would move the
/// body.
class _FooterRoom extends SingleChildRenderObjectWidget {
  const _FooterRoom({
    required this.bodyMetrics,
    required this.padding,
    required this.emptiedKeepsRoom,
    required super.child,
  });

  final ValueListenable<ScrollMetrics?> bodyMetrics;
  final EdgeInsets padding;
  final bool emptiedKeepsRoom;

  @override
  _RenderFooterRoom createRenderObject(BuildContext context) =>
      _RenderFooterRoom(
        bodyMetrics,
        padding: padding,
        emptiedKeepsRoom: emptiedKeepsRoom,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderFooterRoom renderObject,
  ) => renderObject
    ..bodyMetrics = bodyMetrics
    ..padding = padding
    ..emptiedKeepsRoom = emptiedKeepsRoom;
}

/// A render object rather than a measure taken after the frame, so the footer
/// that got shorter and the room kept for it are the same frame: the column
/// lays the footer out before the body, and the body never sees a taller
/// view.
class _RenderFooterRoom extends RenderShiftedBox {
  _RenderFooterRoom(
    this._bodyMetrics, {
    required this._padding,
    required this._emptiedKeepsRoom,
  }) : super(null);

  ValueListenable<ScrollMetrics?> _bodyMetrics;

  /// Keeping room for the footer now.
  bool _keeping = false;

  ValueListenable<ScrollMetrics?> get bodyMetrics => _bodyMetrics;

  set bodyMetrics(ValueListenable<ScrollMetrics?> value) {
    if (identical(value, _bodyMetrics)) return;
    if (attached) {
      _bodyMetrics.removeListener(_onBodyMoved);
      value.addListener(_onBodyMoved);
    }
    _bodyMetrics = value;
    markNeedsLayout();
  }

  /// The footer's insets, which go with a footer that has no height.
  EdgeInsets get padding => _padding;
  EdgeInsets _padding;

  set padding(EdgeInsets value) {
    if (value == _padding) return;
    _padding = value;
    markNeedsLayout();
  }

  /// Whether a footer with no height keeps the room it left.
  bool get emptiedKeepsRoom => _emptiedKeepsRoom;
  bool _emptiedKeepsRoom;

  set emptiedKeepsRoom(bool value) {
    if (value == _emptiedKeepsRoom) return;
    _emptiedKeepsRoom = value;
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _bodyMetrics.addListener(_onBodyMoved);
  }

  @override
  void detach() {
    _bodyMetrics.removeListener(_onBodyMoved);
    super.detach();
  }

  void _onBodyMoved() {
    if (!_keeping) return;
    // A body's scroll activity can change during layout, when its content has
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

  /// How much of [extra] can go without moving the body.
  double _mayGiveBack(double extra) {
    final body = _bodyMetrics.value;
    if (body == null || body.pixels <= body.minScrollExtent) return extra;
    return math.min(extra, body.extentAfter);
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      _keeping = false;
      return;
    }
    child.layout(
      constraints.deflate(_padding).copyWith(minHeight: 0),
      parentUsesSize: true,
    );
    // A footer that draws nothing takes no insets either.
    final empty = child.size.height == 0;
    final natural = empty ? 0.0 : child.size.height + _padding.vertical;
    final extra = !hasSize || (empty && !_emptiedKeepsRoom)
        ? 0.0
        : math.max<double>(0, size.height - natural);
    final height = constraints.constrainHeight(
      natural + extra - _mayGiveBack(extra),
    );
    _keeping = height > natural;
    size = constraints.constrain(
      Size(child.size.width + _padding.horizontal, height),
    );
    // At the foot of the band, so what is left of the footer stays put.
    (child.parentData! as BoxParentData).offset = Offset(
      _padding.left,
      height - natural + (empty ? 0 : _padding.top),
    );
  }
}
