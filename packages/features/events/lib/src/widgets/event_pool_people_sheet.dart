import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:flutter/material.dart';
import 'package:game_filters/game_filters.dart' show GameFilterChipLabel;
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// One person offering games on the Games tab (#516): their roster row's
/// `id`, and the `label` their chip calls them by.
typedef PoolPerson = ({String id, String label});

/// Opens *Whose games* over the Games tab (#516): one chip per person in
/// [people], to show only their games, and a switch to leave them out
/// instead.
///
/// A pop-up ([showBgePopup]), named by its heading. Each change is made to
/// [controller]'s filter as it is made, so the games behind it are already
/// narrowed when it closes; there is nothing to apply. The leave-out switch
/// can be turned only once someone is chosen, and turns off with the last
/// of them ([EventGamesTabController.choose]).
///
/// Completes once it has closed. The caller puts focus back on the button
/// that opened it.
Future<void> showEventPoolPeopleSheet(
  BuildContext context, {
  required EventGamesTabController controller,
  required List<PoolPerson> people,
}) => showBgePopup<void>(
  context,
  semanticLabel: EventsLocalizations.of(context).eventsGamesPeopleTitle,
  builder: (_) => _PeopleSheet(controller: controller, people: people),
);

class _PeopleSheet extends StatelessWidget {
  const _PeopleSheet({required this.controller, required this.people});

  final EventGamesTabController controller;
  final List<PoolPerson> people;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);

    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final filter = controller.filter;
        // Scrolls, so a long list of people at 200% text stays reachable.
        return SingleChildScrollView(
          padding: EdgeInsets.all(tokens.spaceLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Text(
                  l10n.eventsGamesPeopleTitle,
                  style: theme.textTheme.titleLarge,
                ),
              ),
              const BgeGap.md(),
              Wrap(
                spacing: tokens.spaceSm,
                runSpacing: tokens.spaceSm,
                children: [
                  for (final (:id, :label) in people)
                    FilterChip(
                      key: EventDetailScreen.poolPersonKey(id),
                      label: GameFilterChipLabel(label),
                      selected: filter.attendeeIds.contains(id),
                      onSelected: (chosen) =>
                          controller.choose(id, chosen: chosen),
                    ),
                ],
              ),
              const BgeGap.md(),
              SwitchListTile(
                key: EventDetailScreen.poolLeaveOutKey,
                contentPadding: EdgeInsets.zero,
                title: Text(l10n.eventsGamesPeopleLeaveOut),
                value: filter.leaveOut,
                onChanged: filter.attendeeIds.isEmpty
                    ? null
                    : (on) => controller.setLeaveOut(leaveOut: on),
              ),
            ],
          ),
        );
      },
    );
  }
}
