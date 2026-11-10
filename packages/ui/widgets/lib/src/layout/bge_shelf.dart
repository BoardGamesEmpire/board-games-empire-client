import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show
        GestureBinding,
        PointerDeviceKind,
        PointerScrollEvent,
        PointerSignalEvent;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show HardwareKeyboard;
import 'package:ui/src/buttons/bge_inert_button.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A headed row that moves side to side by swipe or by click (#615).
///
/// The row is a [SingleChildScrollView] holding a [Row] rather than a
/// fixed-height list, so it is as tall as its tallest child and a title that
/// grows at 200% text can't clip.
///
/// **By hand.** Touch, trackpad and mouse drag all move the row, and a drag
/// doesn't tap the child it started on. A wheel event that is mostly vertical
/// goes to the page, whether or not it has a little sideways in it, as a
/// trackpad's do on the web. A mostly sideways one, or one with shift held,
/// moves the row, and so does one with no page able to scroll around it.
///
/// **By button.** Previous and next sit in the header, and show only while the
/// row overflows. Each moves by a view of children, less [BgeTokens.spaceXxl]
/// so that what was at the edge stays in sight.
///
/// **By keyboard and screen reader.** Tabbing to a child off screen brings it
/// into view. A button at its end keeps focus, ignores a press and says it is
/// disabled, because a button that really goes disabled drops the focus it
/// holds (#607), and the press that reaches the end would take it.
///
/// [placeholder] stands in for the row, for a state with nothing to show. The
/// header stays the same element through the swap, so an action in it keeps
/// focus.
///
/// [note] is a line between the header and the row, such as one saying where
/// the row's children come from. It goes in and out without the row losing
/// its place or its focus.
///
/// [equalHeights] gives every child the height of the tallest, for children
/// with an edge that would look broken ending at different heights. Each is
/// measured at its own width first, so a title that wraps still counts.
class BgeShelf extends StatefulWidget {
  /// Creates a shelf of [children] under [heading].
  const BgeShelf({
    required this.heading,
    required this.previousLabel,
    required this.nextLabel,
    this.actions = const [],
    this.children = const [],
    this.placeholder,
    this.note,
    this.equalHeights = false,
    this.resetToken,
    this.headingKey,
    super.key,
  });

  /// The previous button.
  static const Key previousKey = Key('bge_shelf.previous');

  /// The next button.
  static const Key nextKey = Key('bge_shelf.next');

  /// The section's name, spoken as a header.
  final String heading;

  /// Says what the previous button brings into view, such as "Previous games".
  final String previousLabel;

  /// Says what the next button brings into view, such as "Next games".
  final String nextLabel;

  /// Controls after the buttons in the header, such as a link to the full list.
  final List<Widget> actions;

  /// The row.
  final List<Widget> children;

  /// Drawn under the header instead of the row when non-null.
  final Widget? placeholder;

  /// Drawn between the header and the row, or the [placeholder], when
  /// non-null.
  final Widget? note;

  /// Whether every child is stretched to the height of the tallest.
  ///
  /// Off, each child keeps its own height, at the top of the row. On, the row
  /// asks each child how tall it is at its own width, which is a second pass
  /// over the children, and so meant for a short row.
  final bool equalHeights;

  /// A change jumps the row back to its start, as for a new set of [children].
  final Object? resetToken;

  /// Put on the heading's text, for a test or to reach it.
  final Key? headingKey;

  @override
  State<BgeShelf> createState() => _BgeShelfState();
}

/// What the row's scroll metrics mean for the buttons.
typedef _Reach = ({bool overflows, bool atStart, bool atEnd});

/// Holds the note's place apart from the placeholder's.
const _noteKey = ValueKey<String>('bge_shelf.note');

/// With no row there is nothing to move, so no buttons.
const _Reach _noRow = (overflows: false, atStart: true, atEnd: true);

class _BgeShelfState extends State<BgeShelf> {
  final ScrollController _controller = ScrollController();

  _Reach _reach = _noRow;
  bool _syncScheduled = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_sync);
  }

  @override
  void didUpdateWidget(BgeShelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Here and not left to the next read: a placeholder is built this frame,
    // and the buttons go with the row rather than a frame after it. The row
    // that comes back reports its own metrics on its first layout.
    if (widget.placeholder != null) _reach = _noRow;
    if (widget.resetToken != oldWidget.resetToken) {
      // After the frame: a jump tells the row's listeners, and this is the
      // middle of a build.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && _controller.hasClients) _controller.jumpTo(0);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  _Reach _read() {
    if (!_controller.hasClients) return _noRow;
    final position = _controller.position;
    if (!position.haveDimensions) return _noRow;
    return (
      overflows:
          position.maxScrollExtent - position.minScrollExtent >
          precisionErrorTolerance,
      atStart: position.extentBefore <= precisionErrorTolerance,
      atEnd: position.extentAfter <= precisionErrorTolerance,
    );
  }

  /// Brings the buttons into line with the row, rebuilding only if they differ.
  void _sync() {
    final reach = _read();
    if (reach == _reach) return;
    // A scroll made during a build or layout can't rebuild this widget now.
    // That frame is under way, so its post-frame callback comes without asking
    // for one, and the setState asks for the next.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_syncScheduled) return;
      _syncScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _syncScheduled = false;
        if (mounted) _sync();
      });
      return;
    }
    setState(() => _reach = reach);
  }

  /// Sends a mostly vertical wheel event to the page, when it has a little dx.
  ///
  /// The framework gives a wheel event to the first scroll view that asks, the
  /// deepest first, and the row asks for any event with a dx it can use. All of
  /// the event then goes to the row, and the page stutters under the pointer.
  /// This sits deeper than the row's scroll view, so it asks first. Everything
  /// else is left to the framework: an event with no dx never reaches the row.
  void _sendToPage(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final Offset(:dx, :dy) = event.scrollDelta;
    if (dx == 0 || dy.abs() <= dx.abs()) return;
    final modifiers = ScrollConfiguration.of(context).pointerAxisModifiers;
    if (HardwareKeyboard.instance.logicalKeysPressed.any(modifiers.contains)) {
      return;
    }
    final page = Scrollable.maybeOf(context, axis: Axis.vertical);
    if (page == null) return;
    final position = page.position;
    if (!position.physics.shouldAcceptUserOffset(position)) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      final before = position.pixels;
      position.pointerScroll(
        axisDirectionIsReversed(page.axisDirection) ? -dy : dy,
      );
      // As the framework answers: the platform leaves alone what scrolled here,
      // and may have an event that scrolled nothing.
      event.respond(allowPlatformDefault: position.pixels == before);
    });
  }

  void _move({required bool forward}) {
    if (!_controller.hasClients) return;
    final tokens = BgeTokens.of(context);
    final position = _controller.position;
    final step = position.viewportDimension - tokens.spaceXxl;
    final target = clampDouble(
      position.pixels + (forward ? step : -step),
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    final duration = BgeMotion.durationOf(context, tokens.motionMedium);
    if (duration == Duration.zero) {
      _controller.jumpTo(target);
    } else {
      _controller.animateTo(
        target,
        duration: duration,
        curve: BgeMotion.standard,
      );
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    // The note goes in before the row, which matches from the end, so the row
    // keeps its element, and so its offset and any focus, as the note comes
    // and goes. Keyed, so that a note of the placeholder's type can't take the
    // placeholder's element, which matches from the start, as it comes.
    children: [
      _header(context),
      const BgeGap.sm(),
      if (widget.note case final note?) ...[
        KeyedSubtree(key: _noteKey, child: note),
        const BgeGap.sm(),
      ],
      widget.placeholder ?? _row(context),
    ],
  );

  /// A [Wrap] so that the controls drop below the heading rather than
  /// overflowing, as at 200% text on a narrow window.
  Widget _header(BuildContext context) => Wrap(
    alignment: WrapAlignment.spaceBetween,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      Semantics(
        header: true,
        child: Text(
          widget.heading,
          key: widget.headingKey,
          style: Theme.of(context).textTheme.titleLarge,
        ),
      ),
      Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        // The actions last: they match by their place from the end, so they
        // keep their elements, and any focus, as the buttons come and go.
        children: [
          if (_reach.overflows) ...[
            _ShelfButton(
              buttonKey: BgeShelf.previousKey,
              icon: Icons.chevron_left,
              label: widget.previousLabel,
              atEnd: _reach.atStart,
              onMove: () => _move(forward: false),
            ),
            _ShelfButton(
              buttonKey: BgeShelf.nextKey,
              icon: Icons.chevron_right,
              label: widget.nextLabel,
              atEnd: _reach.atEnd,
              onMove: () => _move(forward: true),
            ),
          ],
          ...widget.actions,
        ],
      ),
    ],
  );

  Widget _row(BuildContext context) => ScrollConfiguration(
    // Material's behaviour leaves the mouse out.
    behavior: ScrollConfiguration.of(context)
        .copyWith(dragDevices: PointerDeviceKind.values.toSet()),
    child: NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _sync();
        return false;
      },
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        controller: _controller,
        child: Listener(
          // Translucent: over a gap between children too.
          behavior: HitTestBehavior.translucent,
          onPointerSignal: _sendToPage,
          child: widget.equalHeights
              ? IntrinsicHeight(child: _children(CrossAxisAlignment.stretch))
              : _children(CrossAxisAlignment.start),
        ),
      ),
    ),
  );

  Widget _children(CrossAxisAlignment alignment) => Row(
    crossAxisAlignment: alignment,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (final (index, child) in widget.children.indexed) ...[
        if (index > 0) const BgeGap.md(axis: Axis.horizontal),
        child,
      ],
    ],
  );
}

/// An [IconButton] that says it is disabled at its end of the row while staying
/// able to hold focus.
///
/// A material button opens its own semantics node and sets the enabled flag
/// from `onPressed`, which has to stay set for focus to stay. An enclosing
/// `Semantics(enabled: false)` never reaches that node, and merging one in
/// doesn't change what it says or take away its tap. So this is a
/// [BgeInertButton], which replaces the node: the button's semantics are
/// excluded, and its own says what the button's would, with what it should
/// say at an end. A screen reader lands on a button that reads as disabled and
/// has no tap to offer.
///
/// Its name is a label where a material button has a tooltip. VoiceOver only
/// lands on a node with a label, value, hint or action that doesn't scroll, and
/// a tooltip isn't one of those. At an end this node has no action on iOS, so
/// with a tooltip alone VoiceOver would skip it, and the button would vanish
/// under a user who pressed it up to the end. Not both: iOS joins the two and
/// would read the name twice. The tooltip on the [IconButton] is still what
/// hover and long press show.
class _ShelfButton extends StatelessWidget {
  const _ShelfButton({
    required this.buttonKey,
    required this.icon,
    required this.label,
    required this.atEnd,
    required this.onMove,
  });

  final Key buttonKey;
  final IconData icon;
  final String label;
  final bool atEnd;
  final VoidCallback onMove;

  @override
  Widget build(BuildContext context) => BgeInertButton(
    // Inert, not disabled, at an end, or focus would go.
    inert: atEnd,
    label: label,
    onPressed: onMove,
    // Holding Enter or Space down moves along the row, a step per repeat.
    ignoreKeyRepeats: false,
    builder: (context, focusNode, onPressed) => IconButton(
      key: buttonKey,
      focusNode: focusNode,
      tooltip: label,
      icon: Icon(icon),
      style: atEnd ? _atEndStyle(context) : null,
      onPressed: onPressed,
    ),
  );

  /// Drawn as a disabled button is, and with no answer to a press or a hover.
  /// The focus overlay stays, since it is how a keyboard user sees where they
  /// are.
  ButtonStyle _atEndStyle(BuildContext context) {
    final color = Theme.of(context).disabledColor;
    return ButtonStyle(
      foregroundColor: WidgetStatePropertyAll(color),
      overlayColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.focused)
            ? null
            : color.withValues(alpha: 0),
      ),
      mouseCursor: const WidgetStatePropertyAll(SystemMouseCursors.basic),
      splashFactory: NoSplash.splashFactory,
      enableFeedback: false,
    );
  }
}
