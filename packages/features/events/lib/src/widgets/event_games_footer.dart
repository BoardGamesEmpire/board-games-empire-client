import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_event.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/detail/event_games_pool.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What the page's footer holds while the Games tab is selected (#516): how
/// the last of the pool's writes went, then, while the games shown may be
/// out of date, the stale-data banner with Try again. Each when there is
/// one; nothing otherwise. Passed on every build, so the page keeps one
/// shape.
///
/// Both answer the list, which moves on: a read of the pool that fails
/// after a take-back, or after a detail read, lands while the user may be
/// far down it. In the footer each is on screen and heard as it arrives,
/// and moves no row. The most recent answer comes first, so it is read
/// first.
///
/// Each outcome is a banner of its own, built anew, so one that says what
/// the last said is still heard as it lands.
class EventGamesFooter extends StatelessWidget {
  const EventGamesFooter({required this.state, super.key});

  final EventGamesState state;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final gap = BgeTokens.of(context).spaceSm;
    final outcome = state.outcome;
    final message = outcome == null ? null : _message(l10n, outcome);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (outcome != null && message != null)
          KeyedSubtree(
            key: ObjectKey(outcome),
            child: Padding(
              padding: EdgeInsets.only(top: gap),
              child: BgeInlineBanner(
                key: EventDetailScreen.poolOutcomeKey,
                tone: switch (outcome.result) {
                  EventGamesResult.done => BgeBannerTone.success,
                  EventGamesResult.partly ||
                  EventGamesResult.none ||
                  EventGamesResult.refused ||
                  EventGamesResult.stillSupplies ||
                  EventGamesResult.dropped => BgeBannerTone.warning,
                  EventGamesResult.failed => BgeBannerTone.error,
                },
                message: message,
                action: TextButton(
                  onPressed: () => context.read<EventGamesBloc>().add(
                    const EventGamesOutcomeDismissed(),
                  ),
                  child: Text(l10n.eventsActionDismiss),
                ),
              ),
            ),
          ),
        if (state.refreshFailed && state.games.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: gap),
            child: BgeRefreshBanner(
              key: EventDetailScreen.poolRefreshBannerKey,
              retryKey: EventDetailScreen.poolRetryKey,
              failedMessage: l10n.eventsGamesRefreshFailed,
              inProgressLabel: l10n.eventsRefreshInProgress,
              retryLabel: l10n.eventsRefreshRetry,
              refreshing: state.refreshing,
              onRetry: () => retryEventGamesPool(context),
            ),
          ),
      ],
    );
  }

  /// The banner's copy, by the write it answers, or null for none: the
  /// screen sends no offer, so no offer's outcome comes here.
  static String? _message(
    EventsLocalizations l10n,
    EventGamesOutcome outcome,
  ) => switch (outcome.write) {
    EventGamesWrite.offer => null,
    EventGamesWrite.takeBack => _takeBackMessage(l10n, outcome),
  };

  /// A take-back's copy, naming its game; the tab always names it, so one
  /// with no title has none.
  static String? _takeBackMessage(
    EventsLocalizations l10n,
    EventGamesOutcome outcome,
  ) {
    final title = outcome.title;
    if (title == null) return null;
    return switch (outcome.result) {
      EventGamesResult.done => l10n.eventsGamesTakenBack(title),
      EventGamesResult.stillSupplies => l10n.eventsGamesStillSupplies(title),
      EventGamesResult.refused => l10n.eventsGamesTakeBackRefused(title),
      EventGamesResult.dropped => l10n.eventsGamesTakeBackDropped(title),
      // A take-back is one request: it never ends partly, or with none.
      EventGamesResult.failed ||
      EventGamesResult.partly ||
      EventGamesResult.none => l10n.eventsGamesTakeBackFailed(title),
    };
  }
}

/// Reads the pool again, as the person asked (#516), for the event and the
/// roster the detail shows now. Nothing with nobody to read it for.
void retryEventGamesPool(BuildContext context) {
  final state = context.read<EventDetailBloc>().state;
  if (state is! EventDetailReady) return;
  final ids = poolAttendeeIds(state.detail);
  if (ids.isEmpty) return;
  context.read<EventGamesBloc>().add(
    EventGamesRetryRequested(state.detail.snapshot.event.id, ids),
  );
}
