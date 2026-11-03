import 'package:flutter/material.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:events/l10n/events_localizations.dart';

import '../overview/event_groups.dart';
import 'event_labels.dart';

/// One event on the overview or a group's page (#497): its title, when it
/// happens, and where, whose and whether the user is going, as one semantics
/// node. Home shows the same lines on a card instead (#669).
///
/// `EventOverviewScreen.rowKey` is held by the wrapper `BgeKeyedSliverList`
/// puts around each row, not by the row (#549).
///
/// ## The date is the device's
///
/// The date and time are shown in device-local time, with the year only when
/// it isn't this year, by [eventWhenLabel], through which the event's detail
/// screen says its dates too (#498). [eventRowWhenLabel] and [eventRowDetails]
/// build the two lines, which home's card shares (#669).
///
/// ## A row is content until there is somewhere to go
///
/// Without [onOpen] a row is inert content, not a focus stop: a tap that
/// leads nowhere is worse than no tap (#269). The shell passes [onOpen] where
/// it has a detail route for the event (#498), so there a row is a button.
class EventRowTile extends StatelessWidget {
  const EventRowTile({
    required this.row,
    required this.now,
    this.onOpen,
    this.separated = false,
    super.key,
  });

  final EventRow row;

  /// The clock, which decides whether a date is this year's.
  final DateTime Function() now;

  /// Opens the event, or null where there is nowhere to open it. Takes the
  /// id rather than the row, because the destination re-reads the cache.
  final void Function(BuildContext context, String eventId)? onOpen;

  /// Whether a separator follows this row, for every row with another below
  /// it in the same group.
  final bool separated;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final event = row.event;
    final open = onOpen;

    final details = eventRowDetails(l10n, row);

    final tokens = BgeTokens.of(context);

    // MergeSemantics rather than a Semantics container: a tappable ListTile
    // builds an InkWell with its own node, and merging keeps the tap action
    // and the words on one node (the collection row's reasoning). The
    // separator has no node of its own, so merging it in adds nothing.
    //
    // The tile is the Column's first child with or without the separator: a
    // row gains or loses it when a row below arrives or leaves, and a tile
    // that moved in the tree would be thrown away, focus and all, which is
    // what BgeKeyedSliverList exists to prevent (#549).
    return MergeSemantics(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            // Without an onTap the tile's InkWell has no handler, so it is
            // disabled: no tap action, and not a focus stop under ordinary
            // keyboard navigation.
            onTap: open == null ? null : () => open(context, event.id),
            title: Text(event.title),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(eventRowWhenLabel(context, l10n, row, now: now())),
                if (details.isNotEmpty)
                  // Joined differently for the eye and the ear: a screen
                  // reader would read the visual separator's symbol out.
                  Text(
                    details.join(l10n.eventsDetailSeparator),
                    semanticsLabel: details.join(
                      l10n.eventsDetailSpokenSeparator,
                    ),
                  ),
              ],
            ),
          ),
          if (separated)
            Divider(
              color: Theme.of(context).colorScheme.error,
              indent: tokens.separatorInset,
              endIndent: tokens.separatorInset,
              thickness: tokens.separatorThickness,
            ),
        ],
      ),
    );
  }
}
