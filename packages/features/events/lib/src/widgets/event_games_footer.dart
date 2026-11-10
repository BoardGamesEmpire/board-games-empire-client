import 'dart:async';

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

/// What the page's footer holds while the Games tab is selected (#516):
/// first the pool's last write, as the line saying how far a run of offers
/// has got while one is out, then as the banner saying how it went; then,
/// while the games shown may be out of date, the stale-data banner with Try
/// again. Each when there is one; nothing otherwise. Passed on every build,
/// so the page keeps one shape.
///
/// All of them answer the list, which moves on: a run's end, or a read of
/// the pool that fails after a write or a detail read, lands while the user
/// may be far down it. In the footer each is on screen and heard as it
/// arrives, and moves no row. The write's line or banner is drawn first,
/// and the stale-data banner under it.
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

  /// The banner's copy, by the write it answers, or null for none.
  static String? _message(
    EventsLocalizations l10n,
    EventGamesOutcome outcome,
  ) => switch (outcome.write) {
    EventGamesWrite.offer => _offerMessage(l10n, outcome),
    EventGamesWrite.takeBack => _takeBackMessage(l10n, outcome),
  };

  /// A run of offers' copy, by how it ended and what it offered. A run that
  /// stopped after offering some says how many went either way; one that
  /// stopped before offering any says why, refused, or that none went.
  static String _offerMessage(
    EventsLocalizations l10n,
    EventGamesOutcome outcome,
  ) {
    final EventGamesOutcome(:offered, :notOffered) = outcome;
    return switch (outcome.result) {
      EventGamesResult.done => l10n.eventsGamesOfferedAll(offered),
      EventGamesResult.dropped => l10n.eventsGamesOfferDropped,
      EventGamesResult.partly ||
      EventGamesResult.refused ||
      EventGamesResult.failed ||
      EventGamesResult.stillSupplies when offered > 0 =>
        l10n.eventsGamesOfferedPartly(offered, notOffered),
      EventGamesResult.refused => l10n.eventsGamesOfferRefused,
      // A run is never still supplying: that answers a take-back.
      EventGamesResult.partly ||
      EventGamesResult.none ||
      EventGamesResult.failed ||
      EventGamesResult.stillSupplies => l10n.eventsGamesOfferedNone(
        notOffered,
      ),
    };
  }

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
