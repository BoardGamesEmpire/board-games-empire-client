import 'dart:async';

import 'package:events/src/widgets/event_game_quick_look.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// A Games tab row's cover and lines (#957): one button, which opens the
/// quick look of the row's [entry] ([showEventGameQuickLook]). Named by
/// [title], then each of [lines], as one node, so its name starts with what
/// it shows (#919). At least 48dp tall, as any target is.
///
/// Its focus is [focusNode], the tab's
/// ([EventGamesTabController.rowHeadFocus]), so the tab can hand focus to it
/// as a quick look closes. Ringed while it
/// has focus from the keyboard ([BgeFocusRing]); focus a mouse's or a
/// trackpad's press gave it isn't drawn, ring or tint ([BgePointerFocus]).
///
/// A press takes focus, however it came: a screen reader's activation moves
/// no input focus by itself, and the quick look's close hands focus back to
/// the control that last had it on the page. Once the quick look has
/// closed, the tab hands focus on from the scope, which outlives the row:
/// back to this head where its row is still built, else to the row in its
/// place ([EventGamesTabController.focusAfterQuickLook]).
class EventGameRowHead extends StatefulWidget {
  const EventGameRowHead({
    required this.thumbnail,
    required this.title,
    required this.lines,
    required this.entry,
    required this.focusNode,
    super.key,
  });

  /// The cover's address, or null for the placeholder.
  final String? thumbnail;

  /// The game's name, its first line, and the quick look's name.
  final String title;

  /// What the row says under [title].
  final List<Widget> lines;

  /// What the row shows, which the quick look is about.
  final EventGameEntry entry;

  final FocusNode focusNode;

  @override
  State<EventGameRowHead> createState() => _EventGameRowHeadState();
}

class _EventGameRowHeadState extends State<EventGameRowHead>
    with BgePointerFocus<EventGameRowHead> {
  void _open() {
    // Read before the quick look opens: the row can leave while it is open,
    // and take this context with it.
    final entry = widget.entry;
    final controller = EventGamesTabScope.of(context);
    final scope = EventGamesTabScope.contextOf(context);
    widget.focusNode.requestFocus();
    unawaited(
      showEventGameQuickLook(
        context,
        entry: entry,
        title: widget.title,
      ).then((_) {
        if (scope.mounted) controller.focusAfterQuickLook(scope, entry);
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final radius = BorderRadius.circular(BgeTokens.of(context).radiusSm);

    // One node: the title and the lines as its name, and the ink's tap and
    // focus as its actions.
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: BgeFocusRing(
          borderRadius: radius,
          suppressed: pointerFocus,
          builder: (context, onFocusChange) => Material(
            type: MaterialType.transparency,
            child: InkWell(
              focusNode: widget.focusNode,
              onTapDown: (details) => notePointerPress(details.kind),
              onTap: _open,
              onFocusChange: onFocusChange,
              // The theme's tint, with no strength while the focus is a
              // pointer's.
              focusColor: pointerFocusColor,
              borderRadius: radius,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: kMinInteractiveDimension,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    BgeThumbnail(url: widget.thumbnail),
                    const BgeGap.md(axis: Axis.horizontal),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.title, style: theme.textTheme.bodyLarge),
                          ...widget.lines,
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
