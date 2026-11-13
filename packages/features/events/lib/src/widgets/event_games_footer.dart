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
/// saying how many games a run of offers is offering while one is out, then as
/// the banner saying how it went; then the viewer's last nominations write, a
/// nominate, a vote or a withdrawal, or a host's approval, rejection or close
/// of a vote (#518), as the banner saying how it went; then, with [showStale],
/// the stale-data banners: the pool's while the games shown may be out of date,
/// then the nominations' while those shown may be. Each when there is one;
/// nothing otherwise. Passed on every build, on either tab, so the page keeps
/// one shape.
///
/// All of them answer a list, which moves on: a run's end, a vote's, or a
/// read that fails after a write or a detail read, lands while the user may
/// be far down it. In the footer each is on screen and heard as it arrives,
/// and moves no row. The writes' lines and banners are drawn first, the
/// pool's before the nominations', and the stale-data banners under them,
/// in the same order. Each write's banner has its own Dismiss.
///
/// The writes' lines and banners show on either tab: a run of offers can
/// outlast the stay on Games, and its line is a live region that a footer
/// left out on Details would silence. The stale-data banners are about what
/// the tab shows, so they show only while Games is selected ([showStale]),
/// and only over something read before: a first read that fails has nothing
/// stale to warn of.
///
/// Each outcome is a banner of its own, built anew, so one that says what
/// the last said is still heard as it lands.
///
/// A host's close of a vote (#518) says how it came out with the counts the
/// server gave as it settled it, which it stores nowhere: this banner is the
/// only place they show, and a later read of the row carries its status
/// alone.
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
/// still holds it. A take-back of someone else's
/// game (#518) says whose games it is off, or can't come off yet, naming
/// them as the pool's row does, from the roster ([names]); the viewer's own
/// says "your games". The pool's banner keeps the words it landed with: the
/// nominations can change under it, as the viewer withdraws the one it
/// names, and so can the roster, and words that changed would be read out
/// again, saying what no longer holds.
class EventGamesFooter extends StatelessWidget {
  const EventGamesFooter({
    required this.state,
    required this.showStale,
    required this.names,
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

  /// The roster's names, by row id, which name whose games a take-back of
  /// someone else's game was about (#518): empty where the roster is
  /// withheld or not read. Given by every caller, since an empty map names
  /// everyone "this person".
  final Map<String, String?> names;

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
              text: l10n.eventsGamesOffering(sending),
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
        if (nominationsOutcome != null)
          KeyedSubtree(
            key: ObjectKey(nominationsOutcome),
            child: Padding(
              padding: EdgeInsets.only(top: gap),
              child: BgeInlineBanner(
                key: EventDetailScreen.nominationsOutcomeKey,
                tone: _nominationsTone(nominationsOutcome),
                message: _nominationsMessage(l10n, nominationsOutcome),
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
  String? _message(
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
  ///
  /// Whose games it was about comes from the roster row the outcome names
  /// (#518): someone else's where that isn't the viewer's [viewerId], and
  /// they are then named in place of "your games", from [names] as the
  /// pool's row names them, or "this person" where the roster gives no
  /// name. A refusal, a failure and a drop say no one's, and a drop names no
  /// row.
  String? _takeBackMessage(
    EventsLocalizations l10n,
    EventTakeBackOutcome outcome,
    StillSuppliedBy supplied,
  ) {
    final title = outcome.title;
    if (title == null) return null;
    final id = outcome.attendeeId;
    final theirs = id != null && id != viewerId;
    String offeredBy() => names[id] ?? l10n.eventsAttendeeSomeone;
    return switch (outcome.result) {
      EventTakeBackResult.done =>
        theirs
            ? l10n.eventsGamesTheirsTakenBack(title, offeredBy())
            : l10n.eventsGamesTakenBack(title),
      EventTakeBackResult.stillSupplies => switch ((supplied, theirs)) {
        (StillSuppliedBy.viewer, false) => l10n.eventsGamesStillSuppliesYours(
          title,
        ),
        (StillSuppliedBy.viewer, true) =>
          l10n.eventsGamesTheirsStillSuppliesYours(title, offeredBy()),
        (StillSuppliedBy.viewerAndSomeoneElse, false) =>
          l10n.eventsGamesStillSuppliesYoursAndTheirs(title),
        (StillSuppliedBy.viewerAndSomeoneElse, true) =>
          l10n.eventsGamesTheirsStillSuppliesYoursAndTheirs(
            title,
            offeredBy(),
          ),
        (StillSuppliedBy.someoneElse, false) =>
          l10n.eventsGamesStillSuppliesTheirs(title),
        (StillSuppliedBy.someoneElse, true) =>
          l10n.eventsGamesTheirsStillSuppliesTheirs(title, offeredBy()),
        (StillSuppliedBy.none, false) => l10n.eventsGamesStillSupplies(title),
        (StillSuppliedBy.none, true) => l10n.eventsGamesTheirsStillSupplies(
          title,
          offeredBy(),
        ),
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
        HostDecisionOutcome(:final result) => switch (result) {
          HostDecisionResult.done => BgeBannerTone.success,
          HostDecisionResult.changed ||
          HostDecisionResult.refused ||
          HostDecisionResult.gone ||
          HostDecisionResult.dropped => BgeBannerTone.warning,
          HostDecisionResult.failed => BgeBannerTone.error,
        },
        // A vote that didn't pass is still a close that went through.
        ResolveOutcome(:final result) => switch (result) {
          ResolveResult.decided => BgeBannerTone.success,
          ResolveResult.changed ||
          ResolveResult.refused ||
          ResolveResult.gone ||
          ResolveResult.dropped => BgeBannerTone.warning,
          ResolveResult.failed => BgeBannerTone.error,
        },
      };

  /// A nominations write's copy (#517), naming its game. A nominate that
  /// went through says what the server made of it, and a host's close of a
  /// vote how the vote came out (#518).
  static String _nominationsMessage(
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
      HostDecisionOutcome(:final result, :final write) => switch (result) {
        HostDecisionResult.done =>
          write == NominationWrite.approve
              ? l10n.eventsApproved(title)
              : l10n.eventsRejected(title),
        HostDecisionResult.changed => l10n.eventsHostDecisionChanged(title),
        HostDecisionResult.refused => l10n.eventsHostDecisionRefused(title),
        HostDecisionResult.gone => l10n.eventsVoteGone(title),
        HostDecisionResult.failed => l10n.eventsHostDecisionFailed(title),
        HostDecisionResult.dropped => l10n.eventsHostDecisionDropped(title),
      },
      ResolveOutcome(:final result, :final resolution) => switch (result) {
        ResolveResult.decided => _resolvedMessage(l10n, title, resolution),
        ResolveResult.changed => l10n.eventsHostDecisionChanged(title),
        ResolveResult.refused => l10n.eventsHostDecisionRefused(title),
        ResolveResult.gone => l10n.eventsVoteGone(title),
        ResolveResult.failed => l10n.eventsHostDecisionFailed(title),
        ResolveResult.dropped => l10n.eventsHostDecisionDropped(title),
      },
    };
  }

  /// How a host's close of the vote on [title] came out (#518), with the
  /// counts the server gave in [resolution], which are its own, never worked
  /// out here. A result this client can't name, or none, says only that the
  /// vote is closed.
  ///
  /// Its total is the votes the server counted, not those cast: it folds
  /// Interested into For or Against by the event's rules, or leaves it out
  /// (backend `vote-resolver.ts`). So the banner says how many counted. It
  /// says nothing of quorum on a pass or a fail: the server reaches either
  /// only once quorum is met, and an event with no quorum rule meets it
  /// always, so its `quorumMet` is true on both and says nothing.
  static String _resolvedMessage(
    EventsLocalizations l10n,
    String title,
    NominationResolution? resolution,
  ) => switch (resolution) {
    NominationResolution(
      status: NominationStatus.passed,
      :final forCount,
      :final againstCount,
      :final totalVotes,
      :final eligibleVoterCount,
    ) =>
      l10n.eventsResolvedPassed(
        title,
        forCount,
        againstCount,
        totalVotes,
        eligibleVoterCount,
      ),
    NominationResolution(
      status: NominationStatus.failed,
      :final forCount,
      :final againstCount,
      :final totalVotes,
      :final eligibleVoterCount,
    ) =>
      l10n.eventsResolvedFailed(
        title,
        forCount,
        againstCount,
        totalVotes,
        eligibleVoterCount,
      ),
    NominationResolution(
      status: NominationStatus.quorumNotMet,
      :final totalVotes,
      :final eligibleVoterCount,
    ) =>
      l10n.eventsResolvedQuorumNotMet(title, totalVotes, eligibleVoterCount),
    _ => l10n.eventsResolvedSettled(title),
  };
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

/// A run of offers out (#516): a spinner and [text], which says how many
/// games it is offering (#851).
///
/// One live region, the same node for the whole run, saying the same, so a
/// screen reader hears it once, as it appears, never once for the line and
/// again for something around it. A run's end is the outcome banner's to
/// say.
class _OfferProgress extends StatelessWidget {
  const _OfferProgress({required this.text, super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);

    return Semantics(
      container: true,
      liveRegion: true,
      label: text,
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
            Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
          ],
        ),
      ),
    );
  }
}

/// Reads the pool again, as the person asked (#516), for the event the
/// detail shows now and the attendees [poolReadIds] names (#851), and notes
/// the roster's ids ([poolAttendeeIds]) and that read's scope as the ones
/// last asked with, as the screen's own reads do. Nothing with nobody to
/// read it for.
void retryEventGamesPool(BuildContext context) {
  final state = context.read<EventDetailBloc>().state;
  if (state is! EventDetailReady) return;
  final ids = poolAttendeeIds(state.detail);
  if (ids.isEmpty) return;
  final readIds = poolReadIds(state.detail);
  EventGamesTabScope.of(context).requested = (
    ids: ids,
    wholeEvent: readIds == null,
  );
  context.read<EventGamesBloc>().add(
    EventGamesRetryRequested(state.detail.snapshot.event.id, readIds),
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
