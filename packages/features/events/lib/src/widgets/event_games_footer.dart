import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_event.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/detail/event_games_pool.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What the page's footer holds for the games pool (#516): first the pool's
/// last write, as the line saying how far a run of offers has got while one
/// is out, then as the banner saying how it went; then, with [showStale],
/// while the games shown may be out of date, the stale-data banner with Try
/// again. Each when there is one; nothing otherwise. Passed on every build,
/// on either tab, so the page keeps one shape.
///
/// All of them answer the list, which moves on: a run's end, or a read of
/// the pool that fails after a write or a detail read, lands while the user
/// may be far down it. In the footer each is on screen and heard as it
/// arrives, and moves no row. The write's line or banner is drawn first,
/// and the stale-data banner under it.
///
/// The write's line and banner show on either tab: a run of forty sends can
/// outlast the stay on Games, and its line is a live region that a footer
/// left out on Details would silence. The stale-data banner is about the
/// games shown, so it shows only while Games is selected ([showStale]).
///
/// Each outcome is a banner of its own, built anew, so one that says what
/// the last said is still heard as it lands.
class EventGamesFooter extends StatelessWidget {
  const EventGamesFooter({
    required this.state,
    required this.showStale,
    super.key,
  });

  final EventGamesState state;

  /// Whether the Games tab is selected, so the stale-data banner may show.
  final bool showStale;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final gap = BgeTokens.of(context).spaceSm;
    final sending = state.sending;
    final outcome = state.outcome;
    final message = outcome == null ? null : _message(l10n, outcome);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // A run clears the last outcome as it starts, and sets the next as
        // it ends, so the line and the banner never show together.
        if (sending != null)
          Padding(
            padding: EdgeInsets.only(top: gap),
            child: _OfferProgress(
              key: EventDetailScreen.poolProgressKey,
              text: l10n.eventsGamesOffering(sending.done, sending.total),
            ),
          )
        else if (outcome != null && message != null)
          KeyedSubtree(
            key: ObjectKey(outcome),
            child: Padding(
              padding: EdgeInsets.only(top: gap),
              child: BgeInlineBanner(
                key: EventDetailScreen.poolOutcomeKey,
                tone: switch (outcome) {
                  EventOfferOutcome(:final result) => switch (result) {
                    EventOfferResult.done => BgeBannerTone.success,
                    EventOfferResult.partly ||
                    EventOfferResult.none ||
                    EventOfferResult.refused ||
                    EventOfferResult.dropped => BgeBannerTone.warning,
                    EventOfferResult.failed => BgeBannerTone.error,
                  },
                  EventTakeBackOutcome(:final result) => switch (result) {
                    EventTakeBackResult.done => BgeBannerTone.success,
                    EventTakeBackResult.stillSupplies ||
                    EventTakeBackResult.refused ||
                    EventTakeBackResult.dropped => BgeBannerTone.warning,
                    EventTakeBackResult.failed => BgeBannerTone.error,
                  },
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
        if (showStale && state.refreshFailed && state.games.isNotEmpty)
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

  /// The banner's copy, by the write it answers, or null for none.
  static String? _message(
    EventsLocalizations l10n,
    EventGamesOutcome outcome,
  ) => switch (outcome) {
    EventOfferOutcome() => _offerMessage(l10n, outcome),
    EventTakeBackOutcome() => _takeBackMessage(l10n, outcome),
  };

  /// A run of offers' copy, by how it ended and what it offered. A run that
  /// stopped after offering some says how many went either way; one that
  /// stopped before offering any says why, refused, or that none went.
  static String _offerMessage(
    EventsLocalizations l10n,
    EventOfferOutcome outcome,
  ) {
    final EventOfferOutcome(:offered, :notOffered) = outcome;
    return switch (outcome.result) {
      EventOfferResult.done => l10n.eventsGamesOfferedAll(offered),
      EventOfferResult.dropped => l10n.eventsGamesOfferDropped,
      EventOfferResult.partly ||
      EventOfferResult.refused ||
      EventOfferResult.failed when offered > 0 => l10n.eventsGamesOfferedPartly(
        offered,
        notOffered,
      ),
      EventOfferResult.refused => l10n.eventsGamesOfferRefused,
      EventOfferResult.partly ||
      EventOfferResult.none ||
      EventOfferResult.failed => l10n.eventsGamesOfferedNone(notOffered),
    };
  }

  /// A take-back's copy, naming its game; the tab always names it, so one
  /// with no title has none.
  static String? _takeBackMessage(
    EventsLocalizations l10n,
    EventTakeBackOutcome outcome,
  ) {
    final title = outcome.title;
    if (title == null) return null;
    return switch (outcome.result) {
      EventTakeBackResult.done => l10n.eventsGamesTakenBack(title),
      EventTakeBackResult.stillSupplies => l10n.eventsGamesStillSupplies(title),
      EventTakeBackResult.refused => l10n.eventsGamesTakeBackRefused(title),
      EventTakeBackResult.dropped => l10n.eventsGamesTakeBackDropped(title),
      EventTakeBackResult.failed => l10n.eventsGamesTakeBackFailed(title),
    };
  }
}

/// How far a run of offers has got (#516): a spinner and [text], drawn as
/// each pick is settled.
///
/// One live region, the same node for the whole run, so a screen reader
/// hears it as it appears and as it changes, never once for the line and
/// again for something around it. What it says keeps pace with what it
/// draws only so far: a pick can settle many times a second, and a live
/// region speaks every change of its words, queued, so a forty-game run
/// would be read out step by step long after it ended. So each step said
/// stays said for [_held] at least, and the latest step is said once that
/// is up; a run's end is the outcome banner's to say.
class _OfferProgress extends StatefulWidget {
  const _OfferProgress({required this.text, super.key});

  final String text;

  /// The least a step said stays before the next is said: longer than a
  /// screen reader takes to read the line out.
  static const _held = Duration(seconds: 2);

  @override
  State<_OfferProgress> createState() => _OfferProgressState();
}

class _OfferProgressState extends State<_OfferProgress> {
  /// What the live region says.
  late String _said;

  /// Runs while the step said last is held; at its end, the latest step is
  /// said if it differs.
  Timer? _hold;

  @override
  void initState() {
    super.initState();
    _say();
  }

  @override
  void didUpdateWidget(_OfferProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    // While a step is held, the latest waits for the hold's end.
    if (widget.text != _said && _hold == null) _say();
  }

  void _say() {
    _said = widget.text;
    _hold = Timer(_OfferProgress._held, () {
      _hold = null;
      if (mounted && widget.text != _said) setState(_say);
    });
  }

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);

    return Semantics(
      container: true,
      liveRegion: true,
      label: _said,
      child: ExcludeSemantics(
        child: Row(
          children: [
            SizedBox.square(
              dimension: BgeTextScale.clampedOf(
                context,
              ).scale(tokens.spaceMd),
              child: const CircularProgressIndicator(strokeWidth: 2),
            ),
            const BgeGap.sm(axis: Axis.horizontal),
            Expanded(
              child: Text(widget.text, style: theme.textTheme.bodyMedium),
            ),
          ],
        ),
      ),
    );
  }
}

/// Reads the pool again, as the person asked (#516), for the event and the
/// roster the detail shows now, and notes those ids as the ones last asked
/// for, as the screen's own reads do. Nothing with nobody to read it for.
void retryEventGamesPool(BuildContext context) {
  final state = context.read<EventDetailBloc>().state;
  if (state is! EventDetailReady) return;
  final ids = poolAttendeeIds(state.detail);
  if (ids.isEmpty) return;
  EventGamesTabScope.of(context).requestedIds = ids;
  context.read<EventGamesBloc>().add(
    EventGamesRetryRequested(state.detail.snapshot.event.id, ids),
  );
}
