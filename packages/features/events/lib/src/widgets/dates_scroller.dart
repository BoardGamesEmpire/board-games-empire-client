import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A row of dates scrolling sideways under its own scrollbar.
///
/// Material leaves a horizontal scroller with no scrollbar and no mouse drag,
/// and a row of dates takes no focus of its own, so with a mouse or a
/// keyboard the later dates would be out of reach. While the dates
/// [overflows] their room, the bar shows, and this takes focus, its ring
/// round what shows of the dates, and the arrows move them. With nothing to
/// move it is no stop at all.
///
/// A screen reader has each date to land on, and the scroller's own scroll
/// actions, so the focus adds no node for it to stop on.
class DatesScroller extends StatefulWidget {
  const DatesScroller({
    required this.overflows,
    required this.child,
    super.key,
  });

  /// Whether the dates are wider than the room they have.
  final bool overflows;

  final Widget child;

  @override
  State<DatesScroller> createState() => _DatesScrollerState();
}

class _DatesScrollerState extends State<DatesScroller> {
  final ScrollController _controller = ScrollController();
  final FocusNode _focus = FocusNode(debugLabel: 'Dates scroller');

  @override
  void dispose() {
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// Moves the dates half of what shows, towards the dates on the side the
  /// arrow points: which way that is along the scroller follows the text's
  /// direction.
  ///
  /// Keys a focused date leaves alone come here too, so chords pass: Alt+Left
  /// is the browser's Back, and Control and Meta chords are the platform's.
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowLeft => AxisDirection.left,
      LogicalKeyboardKey.arrowRight => AxisDirection.right,
      _ => null,
    };
    if (direction == null) return KeyEventResult.ignored;

    final position = _controller.position;
    final step = position.viewportDimension / 2;
    unawaited(
      position.moveTo(
        position.pixels + (direction == position.axisDirection ? step : -step),
      ),
    );
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = BgeTokens.of(context);
    final ring = Theme.of(context).colorScheme.primary;

    // Round the scroller, not its content: focus reveals what it is on, and
    // would otherwise send the dates to their end as it lands.
    return Focus(
      focusNode: _focus,
      canRequestFocus: widget.overflows,
      includeSemantics: false,
      onKeyEvent: _onKey,
      child: ListenableBuilder(
        listenable: _focus,
        builder: (context, scroller) => DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: _focus.hasPrimaryFocus
                ? Border.all(color: ring, width: tokens.focusOutlineWidth)
                : null,
          ),
          child: scroller,
        ),
        child: Scrollbar(
          controller: _controller,
          thumbVisibility: widget.overflows,
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            // The bar's own room, so its thumb covers no answer.
            child: Padding(
              padding: EdgeInsets.only(
                bottom: widget.overflows ? tokens.spaceMd : 0,
              ),
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}
