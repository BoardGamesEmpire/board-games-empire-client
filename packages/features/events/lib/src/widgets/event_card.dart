import 'dart:math' as math;

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/overview/event_groups.dart';
import 'package:events/src/widgets/event_labels.dart';
import 'package:flutter/material.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One upcoming event on home, in a row that moves side to side (#669): its
/// title, when it happens, and where, whose and whether the user is going, as
/// one semantics node. The lines are the overview's row's, from the same
/// helpers, so the two never say an event two ways.
///
/// ## An outline
///
/// Text beside text with no edge runs together, so each card has one. A game
/// cover in the row below gets away without: its picture is its edge.
///
/// ## A width with a cap
///
/// The card is [baseWidth] at normal text size and grows as its title does,
/// so a title has the width to wrap in at 200%. The growth is read at the
/// title's size rather than by scaling [baseWidth] as if it were one: Android
/// 14 and later scale text nonlinearly, and a size of 240 would barely grow
/// while the title beside it doubled. It stops at [maxWidth], the row's
/// visible width, which the caller has to measure: a horizontal scroll view
/// gives its children no width to measure. The title has no line cap,
/// and the card fills whatever height its parent gives it, so a row can give
/// every card the height of its tallest.
///
/// ## A card is content until there is somewhere to go
///
/// Without [onOpen] a card is inert content, not a focus stop: a tap that
/// leads nowhere is worse than no tap (#269). With it, a card focused from the
/// keyboard is ringed by a [BgeFocusRing] over its outline, as a game cover in
/// the row below is.
class EventCard extends StatelessWidget {
  const EventCard({
    required this.row,
    required this.now,
    required this.maxWidth,
    this.onOpen,
    super.key,
  });

  /// The card's width at normal text size.
  static const double baseWidth = 240;

  final EventRow row;

  /// The clock, which decides whether a date is this year's.
  final DateTime Function() now;

  /// The widest the card may be: the visible width of the row it sits in.
  final double maxWidth;

  /// Opens the event, or null where there is nowhere to open it. Takes the
  /// id rather than the row, because the destination re-reads the cache.
  final void Function(BuildContext context, String eventId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final tokens = BgeTokens.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final textTheme = theme.textTheme;
    final open = onOpen;
    final details = eventRowDetails(l10n, row);
    final secondary = textTheme.bodyMedium?.copyWith(
      color: colors.onSurfaceVariant,
    );
    final titleSize = textTheme.titleMedium?.fontSize ?? kDefaultFontSize;
    final growth =
        MediaQuery.textScalerOf(context).scale(titleSize) / titleSize;

    final radius = BorderRadius.circular(tokens.radiusMd);

    // MergeSemantics rather than a Semantics container, as the overview's row
    // has it: the InkWell builds its own node, and merging keeps the tap
    // action and the words on one node.
    return MergeSemantics(
      child: SizedBox(
        width: math.min(baseWidth * growth, maxWidth),
        child: BgeFocusRing(
          borderRadius: radius,
          builder: (context, onFocusChange) => Card.outlined(
            margin: EdgeInsets.zero,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(
              borderRadius: radius,
              side: BorderSide(color: colors.outlineVariant),
            ),
            child: InkWell(
              // Without an onTap the InkWell has no handler, so it is disabled:
              // no tap action, and not a focus stop.
              onTap: open == null ? null : () => open(context, row.event.id),
              onFocusChange: onFocusChange,
              child: Padding(
                padding: EdgeInsets.all(tokens.spaceMd),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(row.event.title, style: textTheme.titleMedium),
                    const BgeGap.xs(),
                    Text(
                      eventRowWhenLabel(context, l10n, row, now: now()),
                      style: secondary,
                    ),
                    if (details.isNotEmpty) ...[
                      const BgeGap.xs(),
                      // Joined differently for the eye and the ear: a screen
                      // reader would read the visual separator's symbol out.
                      Text(
                        details.join(l10n.eventsDetailSeparator),
                        semanticsLabel: details.join(
                          l10n.eventsDetailSpokenSeparator,
                        ),
                        style: secondary,
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
