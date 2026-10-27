import 'package:models/domain.dart';

import 'package:events/l10n/events_localizations.dart';

// The words for an event's rules, where the create form offers them (#499).
//
// Each label is null for `unknown`, which the form never offers: it stands
// for a value a newer server sent, and has no wire name to send back.

/// A way games get onto the event's lineup.
String? gameAdditionLabel(EventsLocalizations l10n, GameAdditionMode mode) =>
    switch (mode) {
      GameAdditionMode.direct => l10n.gameAdditionDirect,
      GameAdditionMode.requiresVote => l10n.gameAdditionRequiresVote,
      GameAdditionMode.hostApproval => l10n.gameAdditionHostApproval,
      GameAdditionMode.hostOnly => l10n.gameAdditionHostOnly,
      GameAdditionMode.unknown => null,
    };

/// How many votes in favour a game needs to join the lineup, when
/// attendees vote.
String? voteThresholdLabel(EventsLocalizations l10n, VoteThresholdType type) =>
    switch (type) {
      VoteThresholdType.simpleMajority => l10n.voteThresholdSimpleMajority,
      VoteThresholdType.supermajority => l10n.voteThresholdSupermajority,
      VoteThresholdType.unanimous => l10n.voteThresholdUnanimous,
      VoteThresholdType.fixedCount => l10n.voteThresholdFixedCount,
      VoteThresholdType.unknown => null,
    };

/// How many people must vote on a game before the result counts.
String? voteQuorumLabel(EventsLocalizations l10n, VoteQuorumType type) =>
    switch (type) {
      VoteQuorumType.none => l10n.voteQuorumNone,
      VoteQuorumType.percentOfAttendees => l10n.voteQuorumPercent,
      VoteQuorumType.fixedCount => l10n.voteQuorumFixedCount,
      VoteQuorumType.unknown => null,
    };
