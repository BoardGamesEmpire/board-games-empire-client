import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:events/src/widgets/event_labels.dart';
import 'package:flutter/material.dart';
import 'package:game_filters/game_filters.dart' show GameFilterChipLabel;
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Opens the nominations' filters over the Games tab (#517): a chip per
/// status, to keep only the nominations in those; a choice of any date, the
/// whole event, or one of the event's [dates], named as a row names them;
/// then, where [offersMine], a switch keeping the viewer's own, and where
/// [offersNotVoted], one keeping the open nominations they haven't voted on.
///
/// A pop-up ([showBgePopup]), named by its heading. Each change is made to
/// [controller]'s filter as it is made, so the nominations behind it are
/// already narrowed when it closes; there is nothing to apply. It scrolls,
/// and sits above the keyboard, so every control is reachable at 200% text.
///
/// Completes once it has closed. The caller puts focus back on the button
/// that opened it.
Future<void> showNominationFilters(
  BuildContext context, {
  required EventGamesTabController controller,
  required List<EventOccurrence> dates,
  required DateTime now,
  required bool offersMine,
  required bool offersNotVoted,
}) => showBgePopup<void>(
  context,
  semanticLabel: EventsLocalizations.of(context).eventsNominationsFilters,
  builder: (_) => _FiltersSheet(
    controller: controller,
    dates: [...dates]..sort(_byOrder),
    now: now,
    offersMine: offersMine,
    offersNotVoted: offersNotVoted,
  ),
);

/// The event's dates in their order, as the dates section lists them.
int _byOrder(EventOccurrence a, EventOccurrence b) {
  final c = a.sortOrder.compareTo(b.sortOrder);
  return c != 0 ? c : a.id.compareTo(b.id);
}

/// What [group] is called, on its chip in the filters and the chip naming
/// it while it is in use (#517).
String nominationStatusGroupLabel(
  EventsLocalizations l10n,
  NominationStatusGroup group,
) => switch (group) {
  NominationStatusGroup.voting => l10n.eventsNominationStatusVoting,
  NominationStatusGroup.awaitingApproval =>
    l10n.eventsNominationStatusAwaitingApproval,
  NominationStatusGroup.paused => l10n.eventsNominationStatusPaused,
  NominationStatusGroup.decided => l10n.eventsNominationsDecided,
  NominationStatusGroup.withdrawn => l10n.eventsNominationStatusWithdrawn,
};

/// What [scope] is called, in the filters and on the chip naming it while
/// it is in use (#517): as a row says what it is for, from [dates] as of
/// [now]. A date the event no longer has is still named, as gone.
String nominationScopeLabel(
  BuildContext context,
  NominationScope scope, {
  required List<EventOccurrence> dates,
  required DateTime now,
}) {
  final l10n = EventsLocalizations.of(context);
  return switch (scope) {
    WholeEventScope() => l10n.eventsNominationWholeEvent,
    DateScope(:final occurrenceId) => switch (dates
        .where((date) => date.id == occurrenceId)
        .firstOrNull) {
      final date? => l10n.eventsNominationForDate(
        eventDateName(context, date, now: now),
      ),
      null => l10n.eventsNominationsDateGone,
    },
  };
}

class _FiltersSheet extends StatelessWidget {
  const _FiltersSheet({
    required this.controller,
    required this.dates,
    required this.now,
    required this.offersMine,
    required this.offersNotVoted,
  });

  final EventGamesTabController controller;

  /// The event's dates, in their order.
  final List<EventOccurrence> dates;
  final DateTime now;
  final bool offersMine;
  final bool offersNotVoted;

  /// Changes the filter as it stands when [change] runs, not as it stood at
  /// the last build, so two changes in one frame both hold.
  void _change(NominationFilter Function(NominationFilter filter) change) =>
      controller.setNominationFilter(change(controller.nominationFilter));

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final filter = controller.nominationFilter;
        // Above the keyboard, which a sheet doesn't make room for, and
        // scrolling once the dates at 200% text outgrow the screen.
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SingleChildScrollView(
            padding: EdgeInsets.all(tokens.spaceLg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    l10n.eventsNominationsFilters,
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                const BgeGap.md(),
                _Heading(l10n.eventsNominationsStatus),
                const BgeGap.sm(),
                Wrap(
                  spacing: tokens.spaceSm,
                  runSpacing: tokens.spaceSm,
                  children: [
                    for (final group in NominationStatusGroup.values)
                      FilterChip(
                        key: EventDetailScreen.nominationsStatusKey(group),
                        // A chip's label can't wrap, so it scales down.
                        label: GameFilterChipLabel(
                          nominationStatusGroupLabel(l10n, group),
                        ),
                        selected: filter.statuses.contains(group),
                        onSelected: (on) => _change(
                          (filter) => filter.copyWith(
                            statuses: on
                                ? {...filter.statuses, group}
                                : ({...filter.statuses}..remove(group)),
                          ),
                        ),
                      ),
                  ],
                ),
                const BgeGap.md(),
                _Heading(l10n.eventsNominationsDate),
                RadioGroup<NominationScope?>(
                  groupValue: filter.scope,
                  onChanged: (scope) => _change(
                    (filter) => scope == null
                        ? filter.copyWith(clearScope: true)
                        : filter.copyWith(scope: scope),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final scope in <NominationScope?>[
                        null,
                        const WholeEventScope(),
                        for (final date in dates) DateScope(date.id),
                      ])
                        RadioListTile<NominationScope?>(
                          key: EventDetailScreen.nominationsDateKey(scope),
                          value: scope,
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                            scope == null
                                ? l10n.eventsNominationsAnyDate
                                : nominationScopeLabel(
                                    context,
                                    scope,
                                    dates: dates,
                                    now: now,
                                  ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (offersMine)
                  SwitchListTile(
                    key: EventDetailScreen.nominationsMineKey,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.eventsNominationsMine),
                    value: filter.mine,
                    onChanged: (on) =>
                        _change((filter) => filter.copyWith(mine: on)),
                  ),
                if (offersNotVoted)
                  SwitchListTile(
                    key: EventDetailScreen.nominationsNotVotedKey,
                    contentPadding: EdgeInsets.zero,
                    title: Text(l10n.eventsNominationsNotVoted),
                    value: filter.notVotedYet,
                    onChanged: (on) =>
                        _change((filter) => filter.copyWith(notVotedYet: on)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A section's heading in the filters, so heading navigation finds each.
class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}
