import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import 'package:events/l10n/events_localizations.dart';

import '../bloc/event_poll_state.dart';
import '../detail/event_actions.dart';
import '../detail/event_date_actions.dart';
import '../detail/event_poll.dart';
import '../screens/event_detail_screen.dart';
import 'event_labels.dart';

/// The availability poll on an event's dates (#507), as the dates section
/// shows it: worked out by [datesPollView] from the poll's state, the cached
/// event and the viewer's row, so the section only lays it out.
final class DatesPollView {
  const DatesPollView({
    required this.load,
    required this.tallies,
    required this.leaders,
    required this.answers,
    required this.awaiting,
    required this.counts,
    this.failed = false,
    this.retrying = false,
    this.answersOpen = true,
    this.canVoteOn,
    this.onVote,
    this.onRetry,
    this.onWhoAnswered,
  });

  /// Where the read of the poll's answers stands.
  final EventPollLoad load;

  /// Whether the last read of the answers failed. It stays while the next
  /// read runs, so the failed banner and its retry stay in place.
  final bool failed;

  /// Whether the retry's read is under way: the retry stays where it is,
  /// and ignores presses.
  final bool retrying;

  /// The tallies of each Proposed date the summary lists, by occurrence id.
  /// A date it doesn't list shows none.
  final Map<String, OccurrenceAvailability> tallies;

  /// The ids of the leading dates: one is the leader, more are tied, none is
  /// no leader.
  final Set<String> leaders;

  /// The viewer's answer on each date, by occurrence id: the one they sent
  /// or are sending, else the summary's.
  final Map<String, AvailabilityResponse> answers;

  /// How many people whose answers would count haven't answered each date,
  /// by occurrence id. A date with nobody waited on is left out.
  final Map<String, int> awaiting;

  /// Whether the viewer's answers count: false while they've answered that
  /// they aren't attending.
  final bool counts;

  /// Whether the answer chips may be pressed now. While they may not, they
  /// stay in place, disabled.
  ///
  /// Not while a date write or Delete is out, nor until the viewer's own
  /// answers have been read: chips showing nothing would look as if they
  /// never answered, and would invite them to answer again. A read the server
  /// refused will never tell them, so that doesn't hold the chips. A read
  /// running doesn't either, since none can overwrite a vote, and a disabled
  /// chip would drop the focus of a keyboard user on it (#607).
  final bool answersOpen;

  /// Whether the viewer may answer for a date. Null where they may answer for
  /// none, and then no date has chips.
  final bool Function(EventOccurrence occurrence)? canVoteOn;

  /// Sends the viewer's answer on a date. Null offers no chips.
  final void Function(
    EventOccurrence occurrence,
    AvailabilityResponse response,
  )?
  onVote;

  /// Reads the poll again after a failed read. Null offers no retry.
  final VoidCallback? onRetry;

  /// Opens who answered. Null where the roster can't be read, or where there
  /// is nowhere to open it.
  final VoidCallback? onWhoAnswered;
}

/// The poll on [snapshot]'s dates (#507) as [poll] stands, for the viewer
/// on the roster row [viewer], allowed [actions] (from eventActionsFor).
///
/// For an event whose poll the server can be asked about: the screen
/// checks that first, with the check its reads use, so an event created
/// offline shows none.
///
/// The callbacks are offered only where they apply: [onVote] where the
/// viewer may answer some date, [onRetry] after a failed read, and
/// [onWhoAnswered] where the roster can be read. Who hasn't answered is
/// worked out from the roster's rows too, so only where it can be read, only
/// on a date the summary lists, and only while the event takes answers; a
/// date nobody is waited on is left out.
///
/// [acting] says a date write or Delete is out, or the delete is done.
DatesPollView datesPollView({
  required EventSnapshot snapshot,
  required EventAttendee? viewer,
  required Set<EventAction> actions,
  required EventPollState poll,
  required void Function(
    EventOccurrence occurrence,
    AvailabilityResponse response,
  )
  onVote,
  required VoidCallback onRetry,
  VoidCallback? onWhoAnswered,
  bool acting = false,
}) {
  final event = snapshot.event;
  final occurrences = snapshot.occurrences;
  final summary = poll.summary;
  final roster = snapshot.attendees;
  // A summary can withhold a roster the cache still holds, until the detail's
  // read lands. Its empty voters would read as nobody having answered.
  final readable =
      roster != null && roster.isNotEmpty && summary?.rosterVisible != false;

  final tallies = {
    for (final occurrence in occurrences)
      if (occurrence.status == OccurrenceStatus.proposed)
        occurrence.id: ?summary?.of(occurrence.id),
  };
  final answers = {
    for (final occurrence in occurrences)
      occurrence.id:
          ?(poll.pending[occurrence.id] ??
          _answerOf(tallies[occurrence.id], viewer)),
  };
  final awaiting = <String, int>{};
  if (summary != null && readable && takesDateWrites(event)) {
    final rows = pollRows(event, occurrences, roster, summary);
    for (final id in tallies.keys) {
      final count = awaitingAnswer(event, rows, summary, id);
      if (count > 0) awaiting[id] = count;
    }
  }

  bool canVoteOn(EventOccurrence occurrence) =>
      takesVotes(event, occurrence, actions);
  final votes = occurrences.any(canVoteOn);

  return DatesPollView(
    load: poll.load,
    failed: poll.refreshFailed,
    retrying: poll.refreshing,
    answersOpen:
        !acting && (summary != null || poll.load == EventPollLoad.hidden),
    tallies: tallies,
    leaders: summary == null ? const {} : pollLeaders(occurrences, summary),
    answers: answers,
    awaiting: awaiting,
    counts: viewer?.status != EventParticipationStatus.notAttending,
    canVoteOn: votes ? canVoteOn : null,
    onVote: votes ? onVote : null,
    onRetry: poll.refreshFailed ? onRetry : null,
    onWhoAnswered: readable ? onWhoAnswered : null,
  );
}

/// The answer [viewer] gave in [tally], or null for none, or where either is
/// unknown. A voter is matched by their roster row.
AvailabilityResponse? _answerOf(
  OccurrenceAvailability? tally,
  EventAttendee? viewer,
) {
  if (tally == null || viewer == null) return null;
  for (final voter in tally.voters) {
    if (voter.attendeeId == viewer.id) return voter.response;
  }
  return null;
}

/// The poll under one Proposed date (#507): the viewer's answer chips, the
/// date's tallies, its mark where it leads, how many haven't answered, and
/// on the leader alone, *Confirm this date*.
///
/// Each control names its date to a screen reader, which doesn't always say
/// a group's name with each of its children. The tallies and the lines under
/// them are read as one node.
class DatePollBlock extends StatelessWidget {
  const DatePollBlock({
    required this.occurrence,
    required this.poll,
    required this.now,
    required this.enabled,
    this.onConfirm,
    super.key,
  });

  final EventOccurrence occurrence;
  final DatesPollView poll;

  /// The clock's time, which decides how the date is named.
  final DateTime now;

  /// Whether *Confirm this date* may be pressed now. While it may not, it
  /// stays in place, disabled, as the date's menu does. The chips go by
  /// [DatesPollView.answersOpen].
  final bool enabled;

  /// Confirms this date, where the viewer may. Offered on the leader alone.
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final id = occurrence.id;
    final name = eventDateName(context, occurrence, now: now);
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final onVote = poll.onVote;
    final votes = onVote != null && (poll.canVoteOn?.call(occurrence) ?? false);
    final tally = poll.tallies[id];
    final leads = poll.leaders.contains(id);
    final alone = leads && poll.leaders.length == 1;
    final awaiting = poll.awaiting[id];
    final onConfirm = alone ? this.onConfirm : null;
    if (!votes && tally == null && onConfirm == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: EdgeInsets.only(bottom: tokens.spaceSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: tokens.spaceXs,
        children: [
          if (votes)
            Semantics(
              container: true,
              explicitChildNodes: true,
              label: l10n.eventsPollYourAnswer(name),
              child: Wrap(
                spacing: tokens.spaceSm,
                runSpacing: tokens.spaceSm,
                children: [
                  for (final response in const [
                    AvailabilityResponse.available,
                    AvailabilityResponse.maybe,
                    AvailabilityResponse.unavailable,
                  ])
                    if (availabilityResponseLabel(l10n, response)
                        case final label?)
                      ChoiceChip(
                        key: EventDetailScreen.pollAnswerKey(id, response),
                        // A chip can't wrap its label, so one too long for
                        // the width at large text scales down instead.
                        label: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            label,
                            semanticsLabel: l10n.eventsPollAnswerFor(
                              label,
                              name,
                            ),
                          ),
                        ),
                        selected: poll.answers[id] == response,
                        // The chosen answer pressed again changes nothing: the
                        // server keeps one answer a date, and has no way to
                        // take it back.
                        onSelected: poll.answersOpen
                            ? (selected) {
                                if (selected) onVote(occurrence, response);
                              }
                            : null,
                      ),
                ],
              ),
            ),
          if (tally != null)
            MergeSemantics(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Joined differently for the eye and the ear, as the
                  // header's kind line is: a screen reader would read the
                  // symbol out.
                  Text(
                    key: EventDetailScreen.pollTalliesKey(id),
                    l10n.eventsPollTallies(
                      tally.available,
                      tally.maybe,
                      tally.unavailable,
                    ),
                    semanticsLabel: l10n.eventsPollTalliesSpoken(
                      tally.available,
                      tally.maybe,
                      tally.unavailable,
                    ),
                    style: quiet,
                  ),
                  if (leads)
                    Text(
                      key: EventDetailScreen.pollLeaderKey(id),
                      alone ? l10n.eventsPollLeader : l10n.eventsPollTied,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  if (awaiting != null && awaiting > 0)
                    Text(l10n.eventsPollAwaiting(awaiting), style: quiet),
                ],
              ),
            ),
          if (onConfirm != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: EventDetailScreen.confirmLeaderKey(id),
                onPressed: enabled ? onConfirm : null,
                icon: const Icon(Icons.event_available),
                label: Text(
                  l10n.eventsPollConfirmLeader,
                  semanticsLabel: l10n.eventsPollConfirmLeaderFor(name),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The poll's *Try again* after a failed read (#507), on the dates and on
/// who answered. It stays in place, with focus, while the read it started
/// runs.
///
/// A disabled button can't hold focus, so a retry that disabled itself on
/// press would drop a keyboard or screen-reader user's place (#607). This
/// one stays enabled and ignores presses while [busy], showing the read
/// under way. To a screen reader it is one node of its own in place of the
/// button's, which says it isn't available then, and carries the button's
/// focus as `Focus` would.
///
/// `BgeRefreshBanner` keeps the disabling retry for now: #607 settles the
/// refresh banner's, now that #573 made the three copies one. This is the
/// first direction #607 names, so it is what to lift there.
class PollRetryButton extends StatefulWidget {
  const PollRetryButton({required this.busy, required this.onRetry, super.key});

  /// Whether the read a press started is still under way.
  final bool busy;

  /// Reads the poll again.
  final VoidCallback onRetry;

  @override
  State<PollRetryButton> createState() => _PollRetryButtonState();
}

class _PollRetryButtonState extends State<PollRetryButton> {
  final FocusNode _focus = FocusNode(debugLabel: 'PollRetryButton');

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _press() {
    if (!widget.busy) widget.onRetry();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final busy = widget.busy;
    final label = busy ? l10n.eventsRefreshInProgress : l10n.eventsRefreshRetry;

    return ListenableBuilder(
      listenable: _focus,
      builder: (context, button) => Semantics(
        container: true,
        button: true,
        enabled: !busy,
        label: label,
        onTap: busy ? null : _press,
        focusable: true,
        focused: _focus.hasPrimaryFocus,
        // As `Focus` offers it, which leaves it out on iOS.
        onFocus: defaultTargetPlatform == TargetPlatform.iOS
            ? null
            : _focus.requestFocus,
        child: button,
      ),
      child: ExcludeSemantics(
        child: TextButton.icon(
          focusNode: _focus,
          onPressed: _press,
          icon: busy ? const _RetrySpinner() : const Icon(Icons.refresh),
          label: Text(label),
        ),
      ),
    );
  }
}

/// The retry's icon while its read runs, scaled with the label beside it,
/// in the button's icon colour, which a banner sets for its tone.
class _RetrySpinner extends StatelessWidget {
  const _RetrySpinner();

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: BgeTextScale.clampedOf(context)
        .scale(BgeTokens.of(context).spaceMd),
    child: CircularProgressIndicator(
      strokeWidth: 2,
      color: IconTheme.of(context).color,
    ),
  );
}
