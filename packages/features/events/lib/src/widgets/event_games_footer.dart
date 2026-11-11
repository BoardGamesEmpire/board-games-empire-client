import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_games_bloc.dart';
import 'package:events/src/bloc/event_games_event.dart';
import 'package:events/src/bloc/event_games_state.dart';
import 'package:events/src/bloc/event_nominations_bloc.dart';
import 'package:events/src/bloc/event_nominations_event.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:events/src/detail/event_games_pool.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/event_games_tab_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What the page's footer holds for the Games tab: the games pool's (#516),
/// then the nominations' (#517). First the pool's last write, as the line
/// saying how far a run of offers has got while one is out, then as the
/// banner saying how it went; then the viewer's last nominations write, a
/// nominate, a vote or a withdrawal, as the banner saying how it went; then,
/// with [showStale], the stale-data banners: the pool's while the games shown
/// may be out of date, then the nominations' while those shown may be. Each
/// when there is one; nothing otherwise. Passed on every build, on either
/// tab, so the page keeps one shape.
///
/// All of them answer a list, which moves on: a run's end, a vote's, or a
/// read that fails after a write or a detail read, lands while the user may
/// be far down it. In the footer each is on screen and heard as it arrives,
/// and moves no row. The writes' lines and banners are drawn first, the
/// pool's before the nominations', and the stale-data banners under them,
/// in the same order. Each write's banner has its own Dismiss.
///
/// The writes' lines and banners show on either tab: a run of forty sends
/// can outlast the stay on Games, and its line is a live region that a footer
/// left out on Details would silence. The stale-data banners are about what
/// the tab shows, so they show only while Games is selected ([showStale]),
/// and only over something read before: a first read that fails has nothing
/// stale to warn of.
///
/// Each outcome is a banner of its own, built anew, so one that says what
/// the last said is still heard as it lands.
///
/// A take-back the server refuses because the game still supplies a
/// nomination or a lineup (a 409) says what to do where the nominations
/// held can tell (#517): withdraw your nomination first, where only the
/// viewer made a live one the row supplies; that, and that the others who
/// nominated it must withdraw theirs, where both they and someone else did;
/// that only whoever nominated it can withdraw it, where only someone else
/// did; and otherwise that it is nominated or in the lineup, as before,
/// since the lineup is #520's. The row is found by the outcome's offered
/// game id, which is all a nomination names it by, whether or not the pool
/// still holds it. The pool's banner keeps the words it landed with: the
/// nominations can change under it, as the viewer withdraws the one it
/// names, and words that changed would be read out
/// again, saying what no longer holds.
class EventGamesFooter extends StatelessWidget {
  const EventGamesFooter({
    required this.state,
    required this.showStale,
    this.nominations,
    this.viewerId,
    super.key,
  });

  final EventGamesState state;

  /// The nominations' state (#517), whose last write's banner and stale-data
  /// banner follow the pool's. Null shows neither, and a take-back's 409
  /// names no nomination.
  final EventNominationsState? nominations;

  /// The viewer's roster row id, which says which nominations are theirs, or
  /// null where they have none.
  final String? viewerId;

  /// Whether the Games tab is selected, so the stale-data banners may show.
  final bool showStale;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final gap = BgeTokens.of(context).spaceSm;
    final sending = state.sending;
    final outcome = state.outcome;
    final nominations = this.nominations;
    final message = outcome == null
        ? null
        : _message(
            l10n,
            outcome,
            _suppliedBy(
              outcome,
              nominations: nominations?.nominations ?? const [],
              viewerId: viewerId,
            ),
          );
    final nominationsOutcome = nominations?.outcome;
    final nominationsMessage = nominationsOutcome == null
        ? null
        : _nominationsMessage(l10n, nominationsOutcome);

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
              // In the words it landed with, which the nominations' changes
              // leave as they were.
              child: _Landed(
                message: message,
                builder: (context, message) => BgeInlineBanner(
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
          ),
        // The nominations' own, beside the pool's: nothing holds one bloc's
        // write back for the other's, so both can end.
        if (nominationsOutcome != null && nominationsMessage != null)
          KeyedSubtree(
            key: ObjectKey(nominationsOutcome),
            child: Padding(
              padding: EdgeInsets.only(top: gap),
              child: BgeInlineBanner(
                key: EventDetailScreen.nominationsOutcomeKey,
                tone: _nominationsTone(nominationsOutcome),
                message: nominationsMessage,
                action: TextButton(
                  onPressed: () => context.read<EventNominationsBloc>().add(
                    const EventNominationsOutcomeDismissed(),
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
        if (showStale &&
            nominations != null &&
            nominations.refreshFailed &&
            nominations.nominations.isNotEmpty)
          Padding(
            // Keyed, so the pool's banner coming or going above it never
            // takes its place, and a Try again with focus keeps it.
            key: const ValueKey<String>('nominations_stale'),
            padding: EdgeInsets.only(top: gap),
            child: BgeRefreshBanner(
              key: EventDetailScreen.nominationsRefreshBannerKey,
              retryKey: EventDetailScreen.nominationsRetryKey,
              failedMessage: l10n.eventsNominationsRefreshFailed,
              inProgressLabel: l10n.eventsRefreshInProgress,
              retryLabel: l10n.eventsRefreshRetry,
              refreshing: nominations.refreshing,
              onRetry: () => retryEventNominations(context),
            ),
          ),
      ],
    );
  }

  /// The banner's copy, by the write it answers, or null for none. A
  /// take-back's 409 names what to do by [supplied] (#517).
  static String? _message(
    EventsLocalizations l10n,
    EventGamesOutcome outcome,
    StillSuppliedBy supplied,
  ) => switch (outcome) {
    EventOfferOutcome() => _offerMessage(l10n, outcome),
    EventTakeBackOutcome() => _takeBackMessage(l10n, outcome, supplied),
  };

  /// Who holds the live nominations of the pool row a take-back's 409 is
  /// about (#517), in [nominations], for the viewer [viewerId], found by the
  /// row's id, whether or not the pool still holds it. None for any other
  /// outcome, and for one that names no row.
  static StillSuppliedBy _suppliedBy(
    EventGamesOutcome outcome, {
    required List<EventNomination> nominations,
    required String? viewerId,
  }) => switch (outcome) {
    EventTakeBackOutcome(
      result: EventTakeBackResult.stillSupplies,
      offeredGameId: final id?,
    ) =>
      stillSuppliedBy(id, nominations, viewerId: viewerId),
    _ => StillSuppliedBy.none,
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
  /// with no title has none. A 409 says what to do by [supplied] (#517):
  /// where nobody holds a live nomination of the row, it is in the lineup,
  /// or nominated in a way the nominations held don't show.
  static String? _takeBackMessage(
    EventsLocalizations l10n,
    EventTakeBackOutcome outcome,
    StillSuppliedBy supplied,
  ) {
    final title = outcome.title;
    if (title == null) return null;
    return switch (outcome.result) {
      EventTakeBackResult.done => l10n.eventsGamesTakenBack(title),
      EventTakeBackResult.stillSupplies => switch (supplied) {
        StillSuppliedBy.viewer => l10n.eventsGamesStillSuppliesYours(title),
        StillSuppliedBy.someoneElse => l10n.eventsGamesStillSuppliesTheirs(
          title,
        ),
        StillSuppliedBy.viewerAndSomeoneElse =>
          l10n.eventsGamesStillSuppliesYoursAndTheirs(title),
        StillSuppliedBy.none => l10n.eventsGamesStillSupplies(title),
      },
      EventTakeBackResult.refused => l10n.eventsGamesTakeBackRefused(title),
      EventTakeBackResult.dropped => l10n.eventsGamesTakeBackDropped(title),
      EventTakeBackResult.failed => l10n.eventsGamesTakeBackFailed(title),
    };
  }

  /// A nominations write's tone (#517): success where it went through,
  /// error where it failed and trying again may work, and warning where the
  /// server or the screen's own re-check stopped it.
  static BgeBannerTone _nominationsTone(EventNominationsOutcome outcome) =>
      switch (outcome) {
        NominateOutcome(:final result) => switch (result) {
          NominateResult.open ||
          NominateResult.awaitingApproval ||
          NominateResult.inLineup ||
          NominateResult.settled => BgeBannerTone.success,
          NominateResult.refused ||
          NominateResult.supplierNotGoing ||
          NominateResult.notSupplied ||
          NominateResult.gone ||
          NominateResult.dropped => BgeBannerTone.warning,
          NominateResult.failed => BgeBannerTone.error,
        },
        VoteOutcome(:final result) => switch (result) {
          VoteResult.done => BgeBannerTone.success,
          VoteResult.closed ||
          VoteResult.refused ||
          VoteResult.gone ||
          VoteResult.dropped => BgeBannerTone.warning,
          VoteResult.failed => BgeBannerTone.error,
        },
        WithdrawOutcome(:final result) => switch (result) {
          WithdrawResult.done => BgeBannerTone.success,
          WithdrawResult.notWithdrawable ||
          WithdrawResult.refused ||
          WithdrawResult.gone ||
          WithdrawResult.dropped => BgeBannerTone.warning,
          WithdrawResult.failed => BgeBannerTone.error,
        },
        // Unreached: the host decisions' copy comes with their buttons (#518).
        HostDecisionOutcome() || ResolveOutcome() => BgeBannerTone.warning,
      };

  /// A nominations write's copy (#517), naming its game, or null for one
  /// this banner never shows. A nominate that went through says what the
  /// server made of it.
  static String? _nominationsMessage(
    EventsLocalizations l10n,
    EventNominationsOutcome outcome,
  ) {
    final title = outcome.title;
    return switch (outcome) {
      NominateOutcome(:final result) => switch (result) {
        NominateResult.open => l10n.eventsNominatedOpen(title),
        NominateResult.awaitingApproval => l10n.eventsNominatedAwaiting(title),
        NominateResult.inLineup => l10n.eventsNominatedInLineup(title),
        NominateResult.settled => l10n.eventsNominatedSettled(title),
        NominateResult.refused => l10n.eventsNominateRefused(title),
        NominateResult.supplierNotGoing => l10n.eventsNominateSupplierNotGoing(
          title,
        ),
        NominateResult.notSupplied => l10n.eventsNominateNotSupplied(title),
        NominateResult.gone => l10n.eventsNominateGone(title),
        NominateResult.failed => l10n.eventsNominateFailed(title),
        NominateResult.dropped => l10n.eventsNominateDropped(title),
      },
      VoteOutcome(:final result) => switch (result) {
        VoteResult.done => l10n.eventsVoteDone(title),
        VoteResult.closed => l10n.eventsVoteClosed(title),
        VoteResult.refused => l10n.eventsVoteRefused(title),
        VoteResult.gone => l10n.eventsVoteGone(title),
        VoteResult.failed => l10n.eventsVoteFailed(title),
        VoteResult.dropped => l10n.eventsVoteDropped(title),
      },
      WithdrawOutcome(:final result) => switch (result) {
        WithdrawResult.done => l10n.eventsWithdrawDone(title),
        WithdrawResult.notWithdrawable => l10n.eventsWithdrawNotWithdrawable(
          title,
        ),
        WithdrawResult.refused => l10n.eventsWithdrawRefused(title),
        WithdrawResult.gone => l10n.eventsWithdrawGone(title),
        WithdrawResult.failed => l10n.eventsWithdrawFailed(title),
        WithdrawResult.dropped => l10n.eventsWithdrawDropped(title),
      },
      // Unreached: the host decisions' copy comes with their buttons (#518).
      HostDecisionOutcome() || ResolveOutcome() => null,
    };
  }
}

/// Builds [builder] with the first [message] it is given, whatever later
/// builds give it: an outcome's banner in the words it landed with.
class _Landed extends StatefulWidget {
  const _Landed({required this.message, required this.builder});

  final String message;
  final Widget Function(BuildContext context, String message) builder;

  @override
  State<_Landed> createState() => _LandedState();
}

class _LandedState extends State<_Landed> {
  late final String _message;

  @override
  void initState() {
    super.initState();
    _message = widget.message;
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _message);
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

/// Reads the nominations again, as the person asked (#517), for the event
/// the detail shows now, which a reconcile can move (#499). Nothing before
/// the detail is ready. Unlike the pool's, it needs no roster.
void retryEventNominations(BuildContext context) {
  final state = context.read<EventDetailBloc>().state;
  if (state is! EventDetailReady) return;
  context.read<EventNominationsBloc>().add(
    EventNominationsRetryRequested(state.detail.snapshot.event.id),
  );
}
