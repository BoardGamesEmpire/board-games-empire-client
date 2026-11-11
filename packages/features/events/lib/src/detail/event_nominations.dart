/// The rules the nominations section draws from: the tally, the filter and
/// sort, when a deadline's line turns, who is offered Nominate, which pool
/// rows supply a live nomination, and which dates can be nominated for
/// (#517).
///
/// Nothing here reads the network or a bloc. The widgets and the nominations
/// bloc hold the data and ask these what it means.
library;

import 'package:equatable/equatable.dart';
import 'package:events/src/bloc/event_detail_state.dart';
import 'package:events/src/detail/event_actions.dart';
import 'package:events/src/detail/event_date_actions.dart';
import 'package:models/domain.dart';

/// How many of a nomination's counting votes are For, Against and Interested.
typedef NominationTally = ({
  int forCount,
  int againstCount,
  int interestedCount,
});

/// The votes on [n] that count, by type. A vote the server marked ineligible
/// and a vote of unknown type are not counted. How the event weighs Interested
/// is the server's to say, so nothing more is worked out here.
NominationTally tallyOf(EventNomination n) {
  var forCount = 0;
  var againstCount = 0;
  var interestedCount = 0;

  for (final vote in n.votes) {
    if (!vote.eligible) continue;

    switch (vote.voteType) {
      case VoteType.forGame:
        forCount++;
      case VoteType.against:
        againstCount++;
      case VoteType.interested:
        interestedCount++;
      case VoteType.unknown:
        break;
    }
  }

  return (
    forCount: forCount,
    againstCount: againstCount,
    interestedCount: interestedCount,
  );
}

/// The status choices the nominations filter offers.
enum NominationStatusGroup {
  /// [NominationStatus.open].
  voting,
  awaitingApproval,
  paused,

  /// Approved, passed, failed, quorum not met or rejected.
  decided,
  withdrawn,
}

/// The group [status] falls in, or null for a status this client doesn't
/// know, which no status filter matches.
NominationStatusGroup? statusGroupOf(NominationStatus status) =>
    switch (status) {
      NominationStatus.open => NominationStatusGroup.voting,
      NominationStatus.awaitingApproval =>
        NominationStatusGroup.awaitingApproval,
      NominationStatus.paused => NominationStatusGroup.paused,
      NominationStatus.approved ||
      NominationStatus.passed ||
      NominationStatus.failed ||
      NominationStatus.quorumNotMet ||
      NominationStatus.rejected => NominationStatusGroup.decided,
      NominationStatus.withdrawn => NominationStatusGroup.withdrawn,
      NominationStatus.unknown => null,
    };

/// Which nominations a date filter or a Nominate choice means: the whole
/// event's, or one date's.
sealed class NominationScope extends Equatable {
  const NominationScope();
}

/// A nomination made for the event as a whole (no occurrence).
final class WholeEventScope extends NominationScope {
  const WholeEventScope();

  @override
  List<Object?> get props => const [];
}

/// A nomination made for the date [occurrenceId].
final class DateScope extends NominationScope {
  const DateScope(this.occurrenceId);

  final String occurrenceId;

  @override
  List<Object?> get props => [occurrenceId];
}

/// The criteria narrowing the nominations list. Every one set applies
/// together.
final class NominationFilter extends Equatable {
  const NominationFilter({
    this.statuses = const {},
    this.scope,
    this.mine = false,
    this.notVotedYet = false,
  });

  /// The status groups to keep. Empty keeps every status.
  final Set<NominationStatusGroup> statuses;

  /// Null keeps nominations of any scope.
  final NominationScope? scope;

  /// Keep only the viewer's own nominations.
  final bool mine;

  /// Keep only open nominations the viewer hasn't voted on.
  final bool notVotedYet;

  /// Whether any criterion is set.
  bool get narrows =>
      statuses.isNotEmpty || scope != null || mine || notVotedYet;

  /// A copy with the given criteria replaced. [scope] can't be cleared this
  /// way: pass [clearScope].
  NominationFilter copyWith({
    Set<NominationStatusGroup>? statuses,
    NominationScope? scope,
    bool clearScope = false,
    bool? mine,
    bool? notVotedYet,
  }) => NominationFilter(
    statuses: statuses ?? this.statuses,
    scope: clearScope ? null : scope ?? this.scope,
    mine: mine ?? this.mine,
    notVotedYet: notVotedYet ?? this.notVotedYet,
  );

  @override
  List<Object?> get props => [statuses, scope, mine, notVotedYet];
}

/// How the nominations list is ordered.
enum NominationSort {
  /// The server's order.
  newest,

  /// Most For votes among the counting ones first.
  mostSupport,

  /// Earliest voting deadline first, those with none last.
  soonestDeadline,
}

/// The nominations in [all] that meet every criterion of [f], in their order.
///
/// [viewerId] is the viewer's roster row id. With none, [NominationFilter.mine]
/// and [NominationFilter.notVotedYet] keep nothing.
List<EventNomination> filterNominations(
  List<EventNomination> all,
  NominationFilter f, {
  required String? viewerId,
}) {
  final scope = f.scope;

  return [
    for (final n in all)
      if ((f.statuses.isEmpty ||
              f.statuses.contains(statusGroupOf(n.status))) &&
          (scope == null || _inScope(n, scope)) &&
          (!f.mine || (viewerId != null && n.nominatedById == viewerId)) &&
          (!f.notVotedYet ||
              (viewerId != null &&
                  n.status == NominationStatus.open &&
                  !n.votes.any((v) => v.attendeeId == viewerId))))
        n,
  ];
}

bool _inScope(EventNomination n, NominationScope scope) => switch (scope) {
  WholeEventScope() => n.occurrenceId == null,
  DateScope(:final occurrenceId) => n.occurrenceId == occurrenceId,
};

/// [list] ordered by [sort]. A stable sort that leaves [list] alone.
List<EventNomination> sortNominations(
  List<EventNomination> list,
  NominationSort sort,
) {
  final indexed = list.indexed.toList();

  int byIndex(int a, int b) => a.compareTo(b);

  switch (sort) {
    case NominationSort.newest:
      return List.of(list);
    case NominationSort.mostSupport:
      // Each tally once, not once per comparison: a nomination's votes come
      // unbounded (backend#404).
      final support = [for (final n in list) tallyOf(n).forCount];
      indexed.sort((a, b) {
        final c = support[b.$1].compareTo(support[a.$1]);
        return c != 0 ? c : byIndex(a.$1, b.$1);
      });
    case NominationSort.soonestDeadline:
      indexed.sort((a, b) {
        final x = a.$2.votingDeadline;
        final y = b.$2.votingDeadline;
        final c = switch ((x, y)) {
          (null, null) => 0,
          (null, _) => 1,
          (_, null) => -1,
          (final x?, final y?) => x.compareTo(y),
        };
        return c != 0 ? c : byIndex(a.$1, b.$1);
      });
  }

  return [for (final (_, n) in indexed) n];
}

/// When the line of one of [nominations] next turns from "Voting closes" to
/// "Was due to close" after [now] (#517): a millisecond past the soonest
/// deadline still ahead among the open ones, since a deadline has not passed
/// at its own instant. A millisecond, not less: on the web a `DateTime` holds
/// no finer time, so a microsecond past a deadline is the deadline itself,
/// and a timer that fired on it would find the line unturned and none ahead.
/// Null when no open nomination has a deadline ahead.
///
/// The screen builds again then, so an idle screen's line moves on. Nothing
/// closes there: voting carries on until a host closes the vote.
DateTime? nextDeadlinePassing(
  Iterable<EventNomination> nominations, {
  required DateTime now,
}) {
  DateTime? earliest;
  for (final n in nominations) {
    final deadline = n.votingDeadline;
    if (n.status != NominationStatus.open || deadline == null) continue;
    final passing = deadline.add(const Duration(milliseconds: 1));
    if (!passing.isAfter(now)) continue;
    if (earliest == null || passing.isBefore(earliest)) earliest = passing;
  }
  return earliest;
}

/// What [nominateGate] decides for the screen.
enum NominateGate {
  /// Nominate isn't built.
  hidden,

  /// Nominate is offered.
  open,
}

/// Whether the viewer is offered Nominate on [state] (#517).
///
/// [NominateGate.hidden] unless the viewer's actions hold
/// [EventAction.nominateGame], the detail has a row for them on the roster,
/// the event isn't local-only, it takes writes at all ([takesDateWrites]), and
/// the event's mode isn't host-only. An event with no policy, or none the
/// viewer may read, counts as not host-only: the server decides.
NominateGate nominateGate(EventDetailReady state) {
  final event = state.detail.snapshot.event;
  final mode = state.detail.snapshot.policy?.gameAdditionMode;

  if (!state.actions.contains(EventAction.nominateGame) ||
      state.detail.attendance == null ||
      event.isLocalOnly ||
      !takesDateWrites(event) ||
      mode == GameAdditionMode.hostOnly) {
    return NominateGate.hidden;
  }

  return NominateGate.open;
}

/// Whether [game] supplies a live nomination in [all] (open, awaiting
/// approval or paused). With [scope], only one of that scope counts.
bool suppliesLive(
  OfferedGame game,
  List<EventNomination> all, {
  NominationScope? scope,
}) => all.any(
  (n) =>
      n.status.isLive &&
      n.suppliedFromId == game.id &&
      (scope == null || _inScope(n, scope)),
);

/// Who holds the live nominations a pool row still supplies.
enum StillSuppliedBy {
  /// The viewer nominated it, and may withdraw it.
  viewer,

  /// Only someone else has, and only they can withdraw it.
  someoneElse,

  /// No live nomination names the row.
  none,
}

/// Who nominated the live nominations [game] supplies in [all]: the viewer
/// first, when both they and someone else did.
StillSuppliedBy stillSuppliedBy(
  OfferedGame game,
  List<EventNomination> all, {
  required String? viewerId,
}) {
  final live = all.where((n) => n.status.isLive && n.suppliedFromId == game.id);

  if (live.isEmpty) return StillSuppliedBy.none;

  return viewerId != null && live.any((n) => n.nominatedById == viewerId)
      ? StillSuppliedBy.viewer
      : StillSuppliedBy.someoneElse;
}

/// A note the voting control gives the viewer before they vote.
enum VoteHint {
  /// Their vote counts once they are attending.
  countsWhenAttending,

  /// Their vote counts once they offer a game.
  countsWhenOffering,
}

/// What to tell the viewer about whether their vote will count, from the
/// event's [EventPolicy.voteEligibility] and their row, or null when nothing
/// needs saying, as when the event has no readable policy or the viewer has no
/// row. [pool] is the event's offered games.
VoteHint? voteHintFor(
  EventDetailReady state, {
  required List<OfferedGame> pool,
}) {
  final policy = state.detail.snapshot.policy;
  final me = state.detail.attendance;

  if (policy == null || me == null) return null;

  return switch (policy.voteEligibility) {
    VoteEligibility.confirmedOnly
        when me.status != EventParticipationStatus.attending =>
      VoteHint.countsWhenAttending,
    VoteEligibility.poolParticipants
        when !pool.any((g) => g.attendeeId == me.id) =>
      VoteHint.countsWhenOffering,
    _ => null,
  };
}

/// The dates of [detail] a game can be nominated for: proposed or confirmed,
/// and not yet started as of [now] (a date still to be set counts), in
/// `sortOrder`.
List<EventOccurrence> nominatableDates(
  EventDetail detail, {
  required DateTime now,
}) {
  final dates = [
    for (final o in detail.snapshot.occurrences)
      if ((o.status == OccurrenceStatus.proposed ||
              o.status == OccurrenceStatus.confirmed) &&
          (o.startDate == null || o.startDate!.isAfter(now)))
        o,
  ];

  return dates..sort((a, b) {
    final c = a.sortOrder.compareTo(b.sortOrder);
    return c != 0 ? c : a.id.compareTo(b.id);
  });
}
