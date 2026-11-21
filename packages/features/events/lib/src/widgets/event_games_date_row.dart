import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/detail/games_date_view.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/dates_scroller.dart';
import 'package:events/src/widgets/event_labels.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The row of dates above the Games tab's sub-tabs (#1042): a chip for
/// Every date, then one for each of the event's [dates], in the server's
/// order and named as the dialogs name them ([eventDateName]), the [selected]
/// one chosen. It scrolls sideways where the chips outrun the room.
///
/// A chip's label scales down to the width of the row, so a long date name
/// never clips or overflows at 320dp and 200% text. The chosen chip is
/// brought into view when it changes, which is how a date the location names
/// shows where it is. The row is out of the app's selection region and takes
/// a mouse's drag, so a drag moves it where it would select text (#338). A
/// screen reader finds the chips as a group named Dates.
class EventGamesDateRow extends StatefulWidget {
  const EventGamesDateRow({
    required this.dates,
    required this.selected,
    required this.onSelected,
    required this.now,
    super.key,
  });

  /// The event's dates, in the server's order.
  final List<EventOccurrence> dates;

  /// The view the tab shows.
  final GamesDateView selected;

  /// Called with the view a chip chooses, the chosen one included.
  final ValueChanged<GamesDateView> onSelected;

  /// The screen's clock, which names a date that has no label.
  final DateTime now;

  @override
  State<EventGamesDateRow> createState() => _EventGamesDateRowState();
}

class _EventGamesDateRowState extends State<EventGamesDateRow> {
  /// A key to each chip's own place in the row, by its date's id (null for
  /// Every date), to bring it into view without a key that moves.
  final Map<String?, GlobalKey> _places = {};

  /// Each chip's focus node, by its date's id (null for Every date).
  final Map<String?, FocusNode> _nodes = {};

  /// Whether the chips are wider than the room, as the scroller last said.
  bool _overflows = false;

  @override
  void initState() {
    super.initState();
    _revealAfterFrame();
  }

  @override
  void didUpdateWidget(EventGamesDateRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) _revealAfterFrame();
  }

  String? get _selectedId => switch (widget.selected) {
    OneDateView(:final occurrenceId) => occurrenceId,
    EveryDateView() => null,
  };

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _node(String? id) => _nodes.putIfAbsent(
    id,
    () => FocusNode(debugLabel: 'Date ${id ?? 'all'}'),
  );

  GlobalKey _place(String? id) => _places.putIfAbsent(id, GlobalKey.new);

  /// Brings the chosen chip into view once this frame has ended.
  void _revealAfterFrame() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _reveal(_selectedId);
  });

  /// Brings the chip of [id] into view along the row alone: the page's own
  /// scrolling is not the row's to move.
  void _reveal(String? id) {
    final chip = _places[id]?.currentContext;
    final object = chip?.findRenderObject();
    if (chip == null || object == null) return;
    Scrollable.maybeOf(chip)?.position.ensureVisible(
      object,
      duration: BgeMotion.durationOf(
        context,
        BgeTokens.of(context).motionShort,
      ),
      curve: BgeMotion.enter,
    );
  }

  /// Left and Right on a chip move focus to the chip beside it, as the text
  /// runs, and stop at either end. The scroller's own arrows, which move the
  /// row by half a window, are for focus on the scroller itself: with a chip
  /// focused they would scroll it out of sight.
  KeyEventResult _onChipKey(String? id, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    // Alt+Left is the browser's Back, and Control and Meta chords are the
    // platform's: a handled key never reaches them.
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isAltPressed ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowLeft &&
        key != LogicalKeyboardKey.arrowRight) {
      return KeyEventResult.ignored;
    }
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final forward = (key == LogicalKeyboardKey.arrowRight) != rtl;
    final order = [null, for (final date in widget.dates) date.id];
    final at = order.indexOf(id);
    final target = forward ? at + 1 : at - 1;
    if (target >= 0 && target < order.length) {
      _node(order[target]).requestFocus();
    }
    return KeyEventResult.handled;
  }

  bool _onMetrics(ScrollMetricsNotification notification) {
    final overflows = notification.metrics.maxScrollExtent > 0;
    // The scroller sends its metrics after the frame that laid it out, not
    // during that layout, so this can build again at once. A post-frame
    // callback would wait for a frame nothing asks for.
    if (overflows != _overflows && mounted) {
      setState(() => _overflows = overflows);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final ids = {null, for (final date in widget.dates) date.id};
    _places.removeWhere((id, _) => !ids.contains(id));
    // A node goes once its chip has, which this frame has yet to unmount.
    final stale = [
      for (final id in _nodes.keys.where((id) => !ids.contains(id)).toList())
        _nodes.remove(id)!,
    ];
    if (stale.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final node in stale) {
          node.dispose();
        }
      });
    }

    Widget chip(String? id, String label, GamesDateView view, double room) =>
        // Reaches itself as Tab lands on it: focus traversal won't scroll to
        // one that wraps round from the other end of the row.
        Focus(
          key: _place(id),
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          onKeyEvent: (_, event) => _onChipKey(id, event),
          onFocusChange: (focused) {
            if (focused) _reveal(id);
          },
          // No wider than the row: the label is scaled down to what is left.
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: room),
            child: ChoiceChip(
              key: EventDetailScreen.dateChipKey(id),
              focusNode: _node(id),
              label: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: Text(label),
              ),
              selected: widget.selected == view,
              onSelected: (_) => widget.onSelected(view),
            ),
          ),
        );

    return SelectionContainer.disabled(
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: l10n.eventsGamesDatesLabel,
        child: ScrollConfiguration(
          // Material's behaviour leaves the mouse out.
          behavior: ScrollConfiguration.of(
            context,
          ).copyWith(dragDevices: PointerDeviceKind.values.toSet()),
          child: NotificationListener<ScrollMetricsNotification>(
            onNotification: _onMetrics,
            child: LayoutBuilder(
              builder: (context, constraints) => DatesScroller(
                overflows: _overflows,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    chip(
                      null,
                      l10n.eventsGamesEveryDate,
                      const EveryDateView(),
                      constraints.maxWidth,
                    ),
                    for (final date in widget.dates) ...[
                      const BgeGap.sm(axis: Axis.horizontal),
                      chip(
                        date.id,
                        eventDateName(context, date, now: widget.now),
                        OneDateView(date.id),
                        constraints.maxWidth,
                      ),
                    ],
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
