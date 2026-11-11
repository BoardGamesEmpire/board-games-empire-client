import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Where the read of an event's nominations stands (#517).
enum EventNominationsLoad {
  /// Not read yet.
  idle,

  /// A read is out. One that follows a failed read keeps
  /// [EventNominationsState.refreshFailed]. One that follows a [hidden] or a
  /// [gone] keeps that load instead, until it answers: the answer it replaces
  /// is the last word on what this viewer may see.
  loading,

  /// The last read was answered.
  loaded,

  /// The last read failed, or the session check stopped it (#432).
  /// Nominations read before it are kept. A read that started in [gone] and
  /// answers a 404 again is failed too, with no nominations: the event's read
  /// didn't settle it.
  failed,

  /// The server won't show this viewer the nominations: a 403.
  hidden,

  /// The server has no such event: a 404. A screen that shows the event reads
  /// it again, which finds out for the whole screen, and then reads the
  /// nominations again.
  gone,
}

/// Which write a [NominationWriting] or an [EventNominationsOutcome] is about.
enum NominationWrite {
  /// Nominating a game from the pool for the lineup.
  nominate,

  /// Casting the viewer's vote on a nomination, or changing it.
  vote,

  /// Withdrawing the viewer's own nomination.
  withdraw,
}

/// The write that is out: which [NominationWrite], and the id it is about.
/// That is the pool row's id (`OfferedGame.id`) for a nominate, and the
/// nomination's id for a vote or a withdrawal.
typedef NominationWriting = ({NominationWrite write, String id});

/// How a nominate ended (#517). The first four say what the server made of
/// it, read from the status it answered with.
enum NominateResult {
  /// Voting is open on it.
  open,

  /// It waits on the host's decision.
  awaitingApproval,

  /// It went straight into the lineup, as under `GameAdditionMode.direct`.
  inLineup,

  /// The answer carried any other status, which this client doesn't expect
  /// of a new nomination.
  settled,

  /// The server refused the write: a 403.
  refused,

  /// The game's supplier isn't attending the event: a 409.
  supplierNotGoing,

  /// The pool row doesn't supply the game named: a 400.
  notSupplied,

  /// The event, the date or the pool row is gone: a 404. The nominations are
  /// read again.
  gone,

  /// Anything else, a 429 among them, or the session could not be confirmed
  /// as this viewer's (#432).
  failed,

  /// The screen's own re-check stopped the write, and nothing was sent.
  dropped,
}

/// How a vote ended (#517).
enum VoteResult {
  /// The vote is recorded.
  done,

  /// The nomination isn't open for votes now: a 400.
  closed,

  /// The server refused the write: a 403.
  refused,

  /// The nomination or its event is gone: a 404. Its row is dropped.
  gone,

  /// Anything else, a 429 among them, or the session could not be confirmed
  /// as this viewer's (#432).
  failed,

  /// The screen's own re-check stopped the write, and nothing was sent.
  dropped,
}

/// How a withdrawal ended (#517).
enum WithdrawResult {
  /// The nomination is withdrawn.
  done,

  /// The nomination can't be withdrawn in its status now: a 400.
  notWithdrawable,

  /// The server refused the write: a 403.
  refused,

  /// The nomination or its event is gone: a 404. Its row is dropped.
  gone,

  /// Anything else, a 429 among them, or the session could not be confirmed
  /// as this viewer's (#432).
  failed,

  /// The screen's own re-check stopped the write, and nothing was sent.
  dropped,
}

/// How a write ended, for the screen to announce: one case per write.
/// [title] names the game it was about.
sealed class EventNominationsOutcome extends Equatable {
  const EventNominationsOutcome({required this.title});

  /// The game's title: the pool row's for a nominate, and the nomination's
  /// for a vote or a withdrawal, as the event carried it.
  final String title;
}

/// How a nominate ended.
final class NominateOutcome extends EventNominationsOutcome {
  const NominateOutcome(this.result, {required super.title});

  final NominateResult result;

  @override
  List<Object?> get props => [result, title];
}

/// How a vote ended. [voteType] is the vote recorded, on a done, and null
/// otherwise.
final class VoteOutcome extends EventNominationsOutcome {
  const VoteOutcome(this.result, {required super.title, this.voteType});

  final VoteResult result;

  /// The vote cast, when [result] is done.
  final VoteType? voteType;

  @override
  List<Object?> get props => [result, title, voteType];
}

/// How a withdrawal ended.
final class WithdrawOutcome extends EventNominationsOutcome {
  const WithdrawOutcome(this.result, {required super.title});

  final WithdrawResult result;

  @override
  List<Object?> get props => [result, title];
}

/// The nominations on one event's Games tab, and the viewer's write that is
/// out (#517).
///
/// [refreshFailed] and [refreshing] are the detail's own, as
/// `EventDetailReady` has them: with them a screen keeps its failed banner,
/// and the retry in it, in place while the next read runs, so a retry that
/// has focus keeps it.
final class EventNominationsState extends Equatable {
  const EventNominationsState({
    this.load = EventNominationsLoad.idle,
    this.nominations = const [],
    this.writing,
    this.outcome,
    this.refreshFailed = false,
    this.refreshing = false,
  });

  final EventNominationsLoad load;

  /// Every nomination of the event as last read, in the server's order,
  /// newest first. Kept through a later failed read, and cleared by a hidden
  /// or a gone. The viewer's own writes change their rows as they end.
  final List<EventNomination> nominations;

  /// The write that is out, until its outcome comes in.
  final NominationWriting? writing;

  /// A write's end the screen announces. Kept until dismissed, replaced, or
  /// cleared as the next write starts.
  final EventNominationsOutcome? outcome;

  /// Whether the last read to end failed, so [nominations] are the last ones
  /// read, possibly stale, or there are none. A read starting does not clear
  /// it; one that ends any other way does. True whenever [load] is failed.
  final bool refreshFailed;

  /// Whether a read the user asked for, with
  /// `EventNominationsRetryRequested`, is under way: from the request, before
  /// the session is asked, until the reads it joined have ended. The reads
  /// nobody asked for, on open, after a detail read and after a write, are
  /// not narrated.
  final bool refreshing;

  /// Whether a write is out. A write or a dropped write that arrives
  /// meanwhile is ignored.
  bool get busy => writing != null;

  /// This state with the fields given changed. [writing] and [outcome] are
  /// given as a function so each can be set back to null.
  EventNominationsState copyWith({
    EventNominationsLoad? load,
    List<EventNomination>? nominations,
    NominationWriting? Function()? writing,
    EventNominationsOutcome? Function()? outcome,
    bool? refreshFailed,
    bool? refreshing,
  }) => EventNominationsState(
    load: load ?? this.load,
    nominations: nominations ?? this.nominations,
    writing: writing == null ? this.writing : writing(),
    outcome: outcome == null ? this.outcome : outcome(),
    refreshFailed: refreshFailed ?? this.refreshFailed,
    refreshing: refreshing ?? this.refreshing,
  );

  @override
  List<Object?> get props => [
    load,
    nominations,
    writing,
    outcome,
    refreshFailed,
    refreshing,
  ];
}
