/// Where an event game nomination stands (#517).
///
/// Mirrors the backend's `NominationStatus` enum
/// (`prisma/models/event/event-game-nomination.prisma` in
/// `board-games-empire-backend`).
enum NominationStatus {
  /// Accepting votes (a requires-vote event).
  open,

  /// Waiting on the host's decision (a host-approval event).
  awaitingApproval,

  /// The host approved it and it joined the lineup.
  approved,

  /// The vote succeeded and it joined the lineup.
  passed,

  /// The vote did not succeed.
  failed,

  /// Voting ended without reaching quorum.
  quorumNotMet,

  /// The host rejected it.
  rejected,

  /// The nominator pulled it before it was resolved.
  withdrawn,

  /// Its supplier is out of the event; it returns to its `pausedFrom` status
  /// when they are back.
  paused,

  /// A name this client does not know. Never sent.
  unknown;

  /// Whether the nomination is still undecided, so votes or a host decision
  /// can still change it.
  bool get isLive => switch (this) {
    NominationStatus.open ||
    NominationStatus.awaitingApproval ||
    NominationStatus.paused => true,
    _ => false,
  };

  /// Whether the nominated game is on the event's lineup.
  bool get inLineup =>
      this == NominationStatus.approved || this == NominationStatus.passed;

  /// Resolves the backend's enum name, degrading to [unknown] for a name this
  /// client does not know rather than failing the whole row.
  static NominationStatus fromWire(String name) => switch (name) {
    'Open' => NominationStatus.open,
    'AwaitingApproval' => NominationStatus.awaitingApproval,
    'Approved' => NominationStatus.approved,
    'Passed' => NominationStatus.passed,
    'Failed' => NominationStatus.failed,
    'QuorumNotMet' => NominationStatus.quorumNotMet,
    'Rejected' => NominationStatus.rejected,
    'Withdrawn' => NominationStatus.withdrawn,
    'Paused' => NominationStatus.paused,
    _ => NominationStatus.unknown,
  };

  /// The backend's enum name. [unknown] has none: it stands for a name this
  /// client could not read, so it is never sent.
  String toWire() => switch (this) {
    NominationStatus.open => 'Open',
    NominationStatus.awaitingApproval => 'AwaitingApproval',
    NominationStatus.approved => 'Approved',
    NominationStatus.passed => 'Passed',
    NominationStatus.failed => 'Failed',
    NominationStatus.quorumNotMet => 'QuorumNotMet',
    NominationStatus.rejected => 'Rejected',
    NominationStatus.withdrawn => 'Withdrawn',
    NominationStatus.paused => 'Paused',
    NominationStatus.unknown => throw StateError(
      'NominationStatus.unknown has no wire name',
    ),
  };
}
