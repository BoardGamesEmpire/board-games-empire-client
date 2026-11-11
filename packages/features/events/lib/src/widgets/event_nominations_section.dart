import 'dart:async';

import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/bloc/event_detail_bloc.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/bloc/event_nominations_bloc.dart';
import 'package:events/src/bloc/event_nominations_event.dart';
import 'package:events/src/bloc/event_nominations_state.dart';
import 'package:events/src/detail/event_actions.dart';
import 'package:events/src/detail/event_date_actions.dart';
import 'package:events/src/detail/event_detail_write.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/screens/event_detail_screen.dart';
import 'package:events/src/widgets/event_games_footer.dart';
import 'package:events/src/widgets/event_labels.dart';
import 'package:events/src/widgets/event_section_states.dart';
import 'package:events/src/widgets/nomination_vote_control.dart';
import 'package:events/src/widgets/nomination_voters_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// What the Games tab's Nominations section shows under its heading (#517).
enum EventNominationsBody {
  /// The server won't show this viewer the nominations.
  hidden,

  /// Waiting for the first answer, or for the event's own read after the
  /// nominations' found it gone.
  loading,

  /// The read failed, with no nominations read before. Try again reads them
  /// again.
  failed,

  /// Nobody has nominated a game.
  empty,

  /// The nominations.
  rows,
}

/// The Nominations section at the head of an event's Games tab, above the
/// pool (#517): the games nominated for the lineup, one row each, in the
/// server's order, newest first.
///
/// Its slivers, as one group: a heading ([EventGamesTabHeading]), with the
/// count of the rows shown under it while it shows rows; then the rows
/// ([BgeKeyedSliverList], keyed by the nomination's id) or one state; then
/// the gap before the pool's own heading. Each state sits in a
/// [SliverToBoxAdapter], not a [BgeStateSliver]: one would fill the rest of
/// the view and push the pool below it. A first read that
/// fails says so here, with Try again; one that fails over nominations read
/// before leaves them and is the footer's to say.
///
/// A row says, top to bottom: the game and its platform; who nominated it;
/// whose copy it is; whether it is for the whole event or one date; where
/// it stands; its tally of the votes that count, with how this event counts
/// Interested where its policy says; when voting closes, while it is open
/// and has a deadline; and why it is paused, while it is. Read as one node.
/// The row's controls come after that node, outside it, so each is a node of
/// its own: the viewer's vote ([NominationVoteControl]), and *Who voted*.
///
/// Whose copy it is comes from the pool row it was nominated from, and that
/// row's attendee from the roster. The nomination names no attendee of its
/// own (backend#1213), so where the pool no longer holds the row, as when
/// its owner said they aren't coming, it is "whoever brings it". The
/// viewer's own nominations and games say so, as the pool's rows do.
///
/// A deadline is a fixed time, never a countdown (#517). Past it, the row
/// says it stays open until a host closes the vote, since nothing closes it
/// on time yet (backend#797).
///
/// ## Voting
///
/// An open nomination carries the viewer's vote where their actions hold
/// [EventAction.voteGame], they have a row on the roster and the event takes
/// writes ([takesDateWrites]: not cancelled or archived), with the line
/// [voteHintFor] gives above it: the one about offering a game only once
/// [poolRead], since before that the pool can't say what they offer.
///
/// A vote is a direct write: disabled offline (#49), and, as the tab's other
/// writes are, while a detail read runs, whose answer landing after the
/// write would show the event as it was (#589), while the screen's own
/// request is out or the event is deleted ([acting]), and while another
/// nominations write is out. A press waits for any running detail read to
/// end ([readEnded]), then sends only if the event still takes writes, the
/// viewer may still vote and the nomination is still open as the
/// nominations' state holds it; otherwise nothing is sent, and the footer
/// says so. A note goes out with the viewer's vote as that state holds it
/// then; one unchanged sends nothing.
///
/// *Who voted*, on every row with a vote, counts every vote, those that don't
/// count included, and opens [showNominationVoters]: counts alone where the
/// roster was read and withheld, and the votes otherwise. Its focus comes
/// back to it as the list closes.
class EventNominationsSection extends StatelessWidget {
  const EventNominationsSection({
    required this.body,
    required this.rows,
    required this.detail,
    required this.state,
    required this.pool,
    required this.poolRead,
    required this.names,
    required this.acting,
    required this.now,
    super.key,
  });

  final EventNominationsBody body;

  /// The nominations shown, while [body] is rows.
  final List<EventNomination> rows;
  final EventDetailReady detail;
  final EventNominationsState state;

  /// Every game in the pool as last read, whatever its filter keeps: where a
  /// row finds the copy it nominates.
  final List<OfferedGame> pool;

  /// Whether [pool] says what the viewer offers: a read of it has answered,
  /// or it holds games read before.
  final bool poolRead;

  /// The roster's names, by row id.
  final Map<String, String?> names;

  /// Whether the screen's own request is out, or the event is deleted.
  final bool acting;

  /// The screen's clock, which decides whether a deadline has passed and
  /// how a date is named.
  final DateTime now;

  /// Key on the heading's sliver, so it keeps its place as what is under it
  /// changes.
  static const _headingKey = ValueKey<String>('event_nominations.heading');

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final snapshot = detail.detail.snapshot;
    final viewerId = detail.detail.attendance?.id;
    final copies = {for (final game in pool) game.id: game};
    // Not on an event that takes no writes, cancelled or archived, as
    // Nominate isn't.
    final takesWrites = takesDateWrites(snapshot.event);
    final mayVote =
        takesWrites &&
        detail.actions.contains(EventAction.voteGame) &&
        viewerId != null;
    final hint = voteHintFor(detail, pool: pool);
    final voting = mayVote
        ? (
            hint: hint == VoteHint.countsWhenOffering && !poolRead
                ? null
                : hint,
            // As the tab's other writes are (#589): not while a detail read
            // runs, or the screen's own request is out or the event is
            // deleted. The nominations' own writes are the control's to hold.
            enabled: !detail.reading && !acting,
            busy: state.busy,
          )
        : null;
    // A roster read and withheld is an empty list; one not read yet is null,
    // and withholds nothing.
    final rosterShown = !(snapshot.attendees?.isEmpty ?? false);

    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          key: _headingKey,
          child: EventGamesTabHeading(
            title: l10n.eventsNominationsHeading,
            detail: body == EventNominationsBody.rows
                ? l10n.eventsNominationsCount(rows.length)
                : null,
          ),
        ),
        switch (body) {
          EventNominationsBody.hidden => SliverToBoxAdapter(
            child: _State(
              child: BgeEmptyState(
                icon: Icons.visibility_off_outlined,
                title: l10n.eventsNominationsHiddenTitle,
              ),
            ),
          ),
          EventNominationsBody.loading => SliverToBoxAdapter(
            child: EventSectionSpinner(label: l10n.eventsNominationsLoading),
          ),
          EventNominationsBody.failed => SliverToBoxAdapter(
            child: _State(
              child: BgeErrorState(
                icon: Icons.cloud_off_outlined,
                title: l10n.eventsNominationsFailedTitle,
                body: l10n.eventsGamesFailedBody,
                retryLabel: l10n.eventsRefreshRetry,
                retryProgressLabel: l10n.eventsRefreshInProgress,
                retryKey: EventDetailScreen.nominationsRetryKey,
                retrying: state.refreshing,
                onRetry: () => retryEventNominations(context),
              ),
            ),
          ),
          EventNominationsBody.empty => SliverToBoxAdapter(
            child: _State(
              child: BgeEmptyState(
                title: l10n.eventsNominationsEmptyTitle,
                body: l10n.eventsNominationsEmptyBody,
              ),
            ),
          ),
          EventNominationsBody.rows => BgeKeyedSliverList<EventNomination>(
            items: rows,
            keyOf: (nomination) =>
                EventDetailScreen.nominationRowKey(nomination.id),
            itemBuilder: (context, nomination) => _NominationRow(
              nomination: nomination,
              viewerId: viewerId,
              names: names,
              copy: copies[nomination.suppliedFromId],
              occurrences: snapshot.occurrences,
              interestedWeight: snapshot.policy?.interestedWeight,
              voting: voting,
              rosterShown: rosterShown,
              now: now,
            ),
          ),
        },
        const SliverToBoxAdapter(child: BgeGap.lg()),
      ],
    );
  }
}

/// A heading on the Games tab (#517): the Nominations section's, and the
/// pool's under it, so heading navigation finds each. Announced as a
/// heading, with [detail] under it where there is one.
class EventGamesTabHeading extends StatelessWidget {
  const EventGamesTabHeading({required this.title, this.detail, super.key});

  final String title;

  /// A line under the heading, as the Nominations section's count of the
  /// rows it shows. Null draws none.
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = this.detail;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: theme.textTheme.titleMedium),
        ),
        if (detail != null)
          Text(
            detail,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        const BgeGap.sm(),
      ],
    );
  }
}

/// A state in the rows' place, spaced from the heading above it and the pool
/// below.
class _State extends StatelessWidget {
  const _State({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(vertical: BgeTokens.of(context).spaceMd),
    child: Center(child: child),
  );
}

/// What the viewer's vote on each open row needs: the line above it, and
/// whether it may be pressed now ([NominationVoteControl.enabled] and
/// [NominationVoteControl.busy]).
typedef _Voting = ({VoteHint? hint, bool enabled, bool busy});

/// One nomination (#517): its picture, then its lines, read as one node, and
/// under both, outside that node and at the row's full width, the viewer's
/// vote while it is open and *Who voted* once it has a vote.
class _NominationRow extends StatelessWidget {
  const _NominationRow({
    required this.nomination,
    required this.viewerId,
    required this.names,
    required this.copy,
    required this.occurrences,
    required this.interestedWeight,
    required this.voting,
    required this.rosterShown,
    required this.now,
  });

  final EventNomination nomination;

  /// The viewer's roster row id, where they have one.
  final String? viewerId;
  final Map<String, String?> names;

  /// The pool row the nominated copy comes from, or null where the pool
  /// doesn't hold it.
  final OfferedGame? copy;

  /// The event's dates, one of which a nomination may be for.
  final List<EventOccurrence> occurrences;

  /// How the event counts Interested, or null where its policy isn't known.
  final InterestedWeight? interestedWeight;

  /// What the viewer's vote needs, where they may vote; null where they
  /// may not.
  final _Voting? voting;

  /// Whether who voted may name the voters: false where the roster was read
  /// and withheld.
  final bool rosterShown;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final tally = tallyOf(nomination);
    final deadline = nomination.votingDeadline;
    final supplier = _supplier(l10n);
    final scope = _scope(context, l10n);
    final interested = switch (interestedWeight) {
      InterestedWeight.asFor => l10n.eventsNominationInterestedAsFor,
      InterestedWeight.asAgainst => l10n.eventsNominationInterestedAsAgainst,
      InterestedWeight.asAbstain => l10n.eventsNominationInterestedNotCounted,
      InterestedWeight.unknown || null => null,
    };
    // A fixed line, not a countdown: passing it closes nothing (#517).
    final closes =
        deadline == null || nomination.status != NominationStatus.open
        ? null
        : deadline.isBefore(now)
        ? l10n.eventsNominationDeadlinePassed(
            eventWhenLabel(context, deadline, now: now),
          )
        : l10n.eventsNominationDeadline(
            eventWhenLabel(context, deadline, now: now),
          );
    // The server sets where it goes back to whenever it pauses one; a
    // pause without it says Unknown rather than leave a gap.
    final back = _statusLabel(
      l10n,
      nomination.pausedFrom ?? NominationStatus.unknown,
    );
    final paused = nomination.status != NominationStatus.paused
        ? null
        : switch (supplier) {
            _NobodyNamed() => l10n.eventsNominationPausedUnknown(back),
            _Viewer() => l10n.eventsNominationPausedYours(back),
            _Named(:final name) => l10n.eventsNominationPaused(name, back),
          };
    final viewerId = this.viewerId;
    final voting = this.voting;
    final vote = viewerId == null ? null : _viewerVote(nomination, viewerId);
    // Votes are taken while it is open, and only then (#517).
    final control =
        voting == null ||
            viewerId == null ||
            nomination.status != NominationStatus.open
        ? null
        : NominationVoteControl(
            nomination: nomination,
            vote: vote,
            hint: voting.hint,
            enabled: voting.enabled,
            busy: voting.busy,
            onVote: (type) => _vote(context, nomination, type),
            onEditNote: () =>
                _editNote(context, nomination, note: vote?.comment),
          );

    return Padding(
      padding: EdgeInsets.symmetric(vertical: BgeTokens.of(context).spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              BgeThumbnail(url: nomination.thumbnail),
              const BgeGap.md(axis: Axis.horizontal),
              Expanded(
                child: MergeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(nomination.title, style: theme.textTheme.bodyLarge),
                      Text(nomination.platformName, style: quiet),
                      Text(_nominatedBy(l10n), style: quiet),
                      Text(
                        switch (supplier) {
                          _NobodyNamed() => l10n.eventsNominationFromUnknown,
                          _Viewer() => l10n.eventsNominationFromYours,
                          _Named(:final name) => l10n.eventsNominationFrom(
                            name,
                          ),
                        },
                        style: quiet,
                      ),
                      if (scope != null) Text(scope, style: quiet),
                      Text(
                        _statusLabel(l10n, nomination.status),
                        style: theme.textTheme.labelLarge,
                      ),
                      Text(
                        l10n.eventsNominationTally(
                          tally.forCount,
                          tally.againstCount,
                          tally.interestedCount,
                        ),
                        // The symbol between the counts would be read out.
                        semanticsLabel: l10n.eventsNominationTallySpoken(
                          tally.forCount,
                          tally.againstCount,
                          tally.interestedCount,
                        ),
                        style: quiet,
                      ),
                      if (interested != null) Text(interested, style: quiet),
                      if (closes != null) Text(closes, style: quiet),
                      if (paused != null) Text(paused, style: quiet),
                    ],
                  ),
                ),
              ),
            ],
          ),
          // Under the picture and the lines, at the row's full width: the
          // three choices share it, and beside the picture they would have
          // so little that a chosen Interested shrinks to half size at a
          // phone's width and ordinary text.
          if (control != null) ...[const BgeGap.sm(), control],
          if (nomination.votes.isNotEmpty)
            _WhoVoted(
              nomination: nomination,
              names: names,
              rosterShown: rosterShown,
              viewerId: viewerId,
            ),
        ],
      ),
    );
  }

  /// Who nominated it: the viewer, else their name on the roster, else the
  /// username the nomination carries, else "this person", as the pool names
  /// someone the roster doesn't.
  String _nominatedBy(EventsLocalizations l10n) {
    final by = nomination.nominatedById;
    if (viewerId != null && by == viewerId) return l10n.eventsNominatedByYou;
    return l10n.eventsNominatedBy(
      names[by] ??
          personName(username: nomination.nominatedByUsername) ??
          l10n.eventsAttendeeSomeone,
    );
  }

  /// Whose copy it is, from the pool row it was nominated from (#517).
  _Supplier _supplier(EventsLocalizations l10n) {
    final copy = this.copy;
    if (copy == null) return const _NobodyNamed();
    if (viewerId != null && copy.attendeeId == viewerId) return const _Viewer();
    return _Named(names[copy.attendeeId] ?? l10n.eventsAttendeeSomeone);
  }

  /// What it is for: the whole event, or the date it names. Null for a date
  /// the event no longer has, rather than name one it doesn't.
  String? _scope(BuildContext context, EventsLocalizations l10n) {
    final id = nomination.occurrenceId;
    if (id == null) return l10n.eventsNominationWholeEvent;
    final date = occurrences.where((each) => each.id == id).firstOrNull;
    if (date == null) return null;
    return l10n.eventsNominationForDate(
      eventDateName(context, date, now: now),
    );
  }
}

/// The viewer's vote on [nomination], by their roster row [viewerId], or
/// null before they have voted.
EventNominationVote? _viewerVote(EventNomination nomination, String viewerId) =>
    nomination.votes.where((vote) => vote.attendeeId == viewerId).firstOrNull;

/// Sends the viewer's vote of [type] on [nomination] ([_sendVote]).
/// Completes true when it was sent.
Future<bool> _vote(
  BuildContext context,
  EventNomination nomination,
  VoteType type,
) => _sendVote(
  context.read<EventDetailBloc>(),
  context.read<EventNominationsBloc>(),
  nomination,
  type: type,
);

/// Asks for the note on the viewer's vote on [nomination], with [note], the
/// one it has, in the field, and sends it with that vote ([_sendVote]).
/// Completes true when it was sent: false when the dialog was cancelled, or
/// as [_sendVote] has it.
Future<bool> _editNote(
  BuildContext context,
  EventNomination nomination, {
  String? note,
}) async {
  // Read before the dialog opens: the row under it can rebuild without the
  // control, and take this context with it.
  final detail = context.read<EventDetailBloc>();
  final nominations = context.read<EventNominationsBloc>();
  final written = await showNominationNoteDialog(
    context,
    title: nomination.title,
    note: note,
  );
  if (written == null || nominations.isClosed) return false;
  return _sendVote(detail, nominations, nomination, comment: written);
}

/// Sends the viewer's vote on [nomination] once any running detail read of
/// [detail] has ended (#517): of [type], or, with none, of the type of the
/// vote they have, with [comment] where they wrote a note. Completes true
/// when it was added to [nominations].
///
/// It goes for the event as the detail shows it then, whose id a reconcile
/// can have moved (#499), and for the nomination as [nominations] holds it
/// then. Nothing is sent if, by then, the event takes no writes (cancelled
/// or archived), the viewer may no longer vote, or the nomination is gone or
/// no longer open, or a note has no vote to go with: the page shows that
/// already, and the footer says the vote was dropped, or a screen reader
/// would hear nothing happen. A note the same as the one the vote has sends
/// nothing, and says nothing.
Future<bool> _sendVote(
  EventDetailBloc detail,
  EventNominationsBloc nominations,
  EventNomination nomination, {
  VoteType? type,
  String? comment,
}) async {
  final state = await readEnded(detail);
  if (state is! EventDetailReady || nominations.isClosed) return false;

  final viewer = state.detail.attendance;
  final current = nominations.state.nominations
      .where((shown) => shown.id == nomination.id)
      .firstOrNull;
  final own = viewer == null || current == null
      ? null
      : _viewerVote(current, viewer.id);
  final voteType = type ?? own?.voteType;
  if (!takesDateWrites(state.detail.snapshot.event) ||
      !state.actions.contains(EventAction.voteGame) ||
      viewer == null ||
      current == null ||
      current.status != NominationStatus.open ||
      voteType == null ||
      voteType == VoteType.unknown) {
    nominations.add(
      NominationWriteDropped(NominationWrite.vote, title: nomination.title),
    );
    return false;
  }
  // Nothing to send and nothing to say: the note the vote already has.
  if (comment != null && comment == (own?.comment ?? '')) return false;
  // One write at a time; the bloc would ignore this one.
  if (nominations.state.busy) return false;
  nominations.add(
    NominationVoteCast(
      state.detail.snapshot.event.id,
      current,
      voteType,
      comment: comment,
    ),
  );
  return true;
}

/// *Who voted ({count})* on a row with votes (#517): opens
/// [showNominationVoters], and puts focus back on itself once it has closed,
/// however it was opened, since a screen reader's tap moves no focus. Named
/// for its game to a screen reader.
class _WhoVoted extends StatefulWidget {
  const _WhoVoted({
    required this.nomination,
    required this.names,
    required this.rosterShown,
    required this.viewerId,
  });

  final EventNomination nomination;
  final Map<String, String?> names;
  final bool rosterShown;
  final String? viewerId;

  @override
  State<_WhoVoted> createState() => _WhoVotedState();
}

class _WhoVotedState extends State<_WhoVoted> {
  final FocusNode _focus = FocusNode(debugLabel: 'Who voted');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    await showNominationVoters(
      context,
      widget.nomination,
      names: widget.names,
      rosterShown: widget.rosterShown,
      viewerId: widget.viewerId,
    );
    if (mounted && _focus.context != null) _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final nomination = widget.nomination;
    // Every vote, those that don't count included: the list marks them.
    final count = nomination.votes.length;

    return TextButton.icon(
      key: EventDetailScreen.nominationVotersKey(nomination.id),
      focusNode: _focus,
      onPressed: () => unawaited(_open()),
      icon: const Icon(Icons.how_to_vote_outlined),
      label: Text(
        l10n.eventsVotersOpen(count),
        semanticsLabel: l10n.eventsVotersOpenNamed(count, nomination.title),
      ),
    );
  }
}

/// Who brings a nominated copy: someone named, the viewer, or nobody the
/// pool can name.
sealed class _Supplier {
  const _Supplier();
}

/// Someone other than the viewer.
final class _Named extends _Supplier {
  const _Named(this.name);

  /// Their name on the roster, or "this person".
  final String name;
}

/// The viewer.
final class _Viewer extends _Supplier {
  const _Viewer();
}

/// Nobody the pool can name: it no longer holds the row.
final class _NobodyNamed extends _Supplier {
  const _NobodyNamed();
}

/// Where a nomination stands, as its row says it. Unlike the event's own
/// labels, an unknown status has one: a paused row names the status it goes
/// back to, and needs a word for one this client can't read.
String _statusLabel(EventsLocalizations l10n, NominationStatus status) =>
    switch (status) {
      NominationStatus.open => l10n.eventsNominationStatusVoting,
      NominationStatus.awaitingApproval =>
        l10n.eventsNominationStatusAwaitingApproval,
      NominationStatus.approved => l10n.eventsNominationStatusApproved,
      NominationStatus.passed => l10n.eventsNominationStatusPassed,
      NominationStatus.failed => l10n.eventsNominationStatusFailed,
      NominationStatus.quorumNotMet => l10n.eventsNominationStatusQuorumNotMet,
      NominationStatus.rejected => l10n.eventsNominationStatusRejected,
      NominationStatus.withdrawn => l10n.eventsNominationStatusWithdrawn,
      NominationStatus.paused => l10n.eventsNominationStatusPaused,
      NominationStatus.unknown => l10n.eventsNominationStatusUnknown,
    };
