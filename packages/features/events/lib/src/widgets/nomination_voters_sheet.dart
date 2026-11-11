import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/detail/event_nominations.dart';
import 'package:events/src/widgets/nomination_vote_control.dart';
import 'package:flutter/material.dart';
import 'package:models/domain.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Opens who voted on [nomination] (#517), as it stood when opened: under
/// its heading, the tally of the votes that count, then each vote, "{name}:
/// {vote}", with the voter's note under it.
///
/// A vote that doesn't count (`eligible` false) stays in the list, struck
/// through, and says so to a screen reader; one line above the list gives the
/// reasons, where it holds one (#462). Each voter is named from [names], the
/// roster's names by row id, else as "This person"; the viewer, by
/// [viewerId], as "You", as the section names them.
///
/// Where [rosterShown] is false, as when the server withholds the roster from
/// this viewer, it shows the tally alone and says who voted isn't shown
/// (#517). Where a vote doesn't count, a line above says some don't, so the
/// count on *Who voted*, which counts every vote, is explained beside a
/// smaller tally.
///
/// A pop-up ([showBgePopup]), named by its heading. Completes once it has
/// closed. The caller puts focus back on the button that opened it.
Future<void> showNominationVoters(
  BuildContext context,
  EventNomination nomination, {
  required Map<String, String?> names,
  required bool rosterShown,
  String? viewerId,
}) => showBgePopup<void>(
  context,
  semanticLabel: EventsLocalizations.of(
    context,
  ).eventsVotersTitle(nomination.title),
  builder: (_) => _VotersSheet(
    nomination: nomination,
    names: names,
    rosterShown: rosterShown,
    viewerId: viewerId,
  ),
);

class _VotersSheet extends StatelessWidget {
  const _VotersSheet({
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
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final tokens = BgeTokens.of(context);
    final quiet = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final tally = tallyOf(nomination);
    final votes = nomination.votes;
    final struck = votes.any((vote) => !vote.eligible);

    // Above the keyboard, which a sheet doesn't make room for, and scrolling
    // once a long list at 200% text outgrows the screen.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: EdgeInsets.all(tokens.spaceLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              header: true,
              child: Text(
                l10n.eventsVotersTitle(nomination.title),
                style: theme.textTheme.titleLarge,
              ),
            ),
            const BgeGap.sm(),
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
            const BgeGap.md(),
            if (!rosterShown) ...[
              // The button counted every vote, so a count above the tally's
              // total is explained, though no vote is drawn to strike.
              if (struck) ...[
                Text(l10n.eventsVotersNotCountingCountsOnly, style: quiet),
                const BgeGap.md(),
              ],
              Text(l10n.eventsVotersHidden, style: theme.textTheme.bodyMedium),
            ] else ...[
              if (struck) ...[
                Text(l10n.eventsVotersNotCountingNote, style: quiet),
                const BgeGap.md(),
              ],
              for (final vote in votes)
                _VoteLine(vote: vote, name: _nameOf(l10n, vote.attendeeId)),
            ],
          ],
        ),
      ),
    );
  }

  /// The voter on the roster row [attendeeId]: "You" for the viewer, else
  /// their name on the roster, else "This person".
  String _nameOf(EventsLocalizations l10n, String attendeeId) =>
      viewerId != null && attendeeId == viewerId
      ? l10n.eventsVoterYou
      : names[attendeeId] ?? l10n.eventsAttendeeSomeoneStart;
}

/// One vote, and the note under it, read as one node. Struck through where
/// it doesn't count, which its spoken label says in words.
class _VoteLine extends StatelessWidget {
  const _VoteLine({required this.vote, required this.name});

  final EventNominationVote vote;
  final String name;

  @override
  Widget build(BuildContext context) {
    final l10n = EventsLocalizations.of(context);
    final theme = Theme.of(context);
    final quiet = theme.colorScheme.onSurfaceVariant;
    final type = voteTypeLabel(l10n, vote.voteType);
    final note = vote.comment;
    final counts = vote.eligible;

    return Padding(
      padding: EdgeInsets.only(bottom: BgeTokens.of(context).spaceSm),
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.eventsVoterLine(name, type),
              semanticsLabel: counts
                  ? null
                  : l10n.eventsVoterLineNotCounting(name, type),
              style: counts
                  ? theme.textTheme.bodyLarge
                  : theme.textTheme.bodyLarge?.copyWith(
                      color: quiet,
                      decoration: TextDecoration.lineThrough,
                    ),
            ),
            if (note != null && note.isNotEmpty)
              Text(
                note,
                style: theme.textTheme.bodyMedium?.copyWith(color: quiet),
              ),
          ],
        ),
      ),
    );
  }
}
