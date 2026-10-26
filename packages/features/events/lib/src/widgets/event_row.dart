import 'package:flutter/material.dart';

import 'package:events/l10n/events_localizations.dart';

import '../overview/event_groups.dart';
import 'event_labels.dart';

/// One event on the overview or a group's page (#497): its title, when it
/// happens, and where, whose and whether the user is going, as one
/// semantics node.
///
/// The caller keys it with `EventOverviewScreen.rowKey`.
///
/// ## The date is the device's
///
/// The date and time are shown in device-local time. The day is an ARB
/// `DateTime` placeholder, as the collection's last-played date is, with the
/// year only when it isn't this year. The time comes from
/// [MaterialLocalizations.formatTimeOfDay], told the platform's 24-hour
/// setting, rather than from `intl`: `intl` follows the locale alone, so a
/// user who set 24-hour time on a 12-hour locale would get the 12-hour form.
/// The event's detail screen says its dates the same way, through the same
/// `eventWhenLabel` (#498).
///
/// ## A row is content until there is somewhere to go
///
/// Without [onOpen] a row is inert content, not a focus stop: a tap that
/// leads nowhere is worse than no tap (#269). #498 wires it.
class EventRowTile extends StatelessWidget {
  const EventRowTile({
    required this.row,
    required this.now,
    this.onOpen,
    super.key,
  });

  final EventRow row;

  /// The clock, which decides whether a date is this year's.
  final DateTime Function() now;

  /// Opens the event, or null where there is nowhere to open it. Takes the
  /// id rather than the row, because the destination re-reads the cache.
  final void Function(BuildContext context, String eventId)? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final event = row.event;
    final open = onOpen;

    final details = [
      ?row.venue,
      ?row.householdName,
      // An answer this client can't read is not a guess at one.
      ?eventRsvpLabel(l10n, row.rsvp),
    ];

    // MergeSemantics rather than a Semantics container: a tappable ListTile
    // builds an InkWell with its own node, and merging keeps the tap action
    // and the words on one node (the collection row's reasoning).
    return MergeSemantics(
      child: ListTile(
        // Without an onTap the tile's InkWell has no handler, so it is
        // disabled: no tap action, and not a focus stop under ordinary
        // keyboard navigation.
        onTap: open == null ? null : () => open(context, event.id),
        title: Text(event.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_when(context, l10n)),
            if (details.isNotEmpty)
              // Joined differently for the eye and the ear: a screen reader
              // would read the visual separator's symbol out.
              Text(
                details.join(l10n.eventsDetailSeparator),
                semanticsLabel: details.join(l10n.eventsDetailSpokenSeparator),
              ),
          ],
        ),
      ),
    );
  }

  String _when(BuildContext context, EventsLocalizations l10n) {
    final start = row.date?.startDate;
    if (start == null) {
      return row.dateBeingChosen
          ? l10n.eventsDateBeingChosen
          : l10n.eventsNoDateYet;
    }

    return eventWhenLabel(context, start, now: now());
  }
}
