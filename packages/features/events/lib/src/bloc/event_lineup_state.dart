import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Where the read of an event's lineup stands (#519).
enum EventLineupLoad {
  /// Not read yet.
  idle,

  /// A read is out. One that follows a failed read keeps
  /// [EventLineupState.refreshFailed]. One that follows a [hidden] or a
  /// [gone] keeps that load instead, until it answers: the answer it replaces
  /// is the last word on what this viewer may see.
  loading,

  /// The last read was answered.
  loaded,

  /// The last read failed, or the session check stopped it (#432). The games
  /// read before it are kept. A read that started in [gone] and answers a 404
  /// again is failed too, with no games: the event's read didn't settle it.
  failed,

  /// The server won't show this viewer the lineup: a 403.
  hidden,

  /// The server has no such event: a 404. A screen that shows the event reads
  /// it again, which finds out for the whole screen, and then reads the
  /// lineup again.
  gone,
}

/// Which write a [LineupWriting] or an [EventLineupOutcome] is about.
enum LineupWrite {
  /// A host adding a game from the pool straight to the lineup (#519).
  add,

  /// A host taking a game out of the lineup (#520).
  remove,
}

/// The write that is out: which [LineupWrite], and the id it is about. That
/// is the pool row's id (`OfferedGame.id`) for an add, and the lineup game's
/// id for a removal.
typedef LineupWriting = ({LineupWrite write, String id});

/// How an add ended (#519).
enum LineupAddResult {
  /// The game is in the lineup. The lineup is read again.
  done,

  /// The server refused the write: a 403.
  refused,

  /// The pool row, or the game's supplier, is gone: a 404.
  supplierGone,

  /// The game's supplier isn't attending the event: a 409.
  supplierNotGoing,

  /// Anything else, a 429 among them, or the session could not be confirmed
  /// as this viewer's (#432).
  failed,

  /// The screen's own re-check stopped the write, and nothing was sent.
  dropped,
}

/// How a removal ended (#520).
enum LineupRemoveResult {
  /// The game is out of the lineup.
  done,

  /// The game isn't in the lineup any more: a 404. Its row is dropped.
  alreadyGone,

  /// The lineup has started, or the event was called off: a 409. It is read
  /// again.
  started,

  /// The server refused the write: a 403.
  refused,

  /// Anything else, a 429 among them, or the session could not be confirmed
  /// as this viewer's (#432).
  failed,

  /// The screen's own re-check stopped the write, and nothing was sent.
  dropped,
}

/// How a lineup write ended, for the screen to announce. [title] names the
/// game it was about, and [subtitle] follows it where the game has one.
sealed class EventLineupOutcome extends Equatable {
  const EventLineupOutcome({required this.title, this.subtitle});

  final String title;
  final String? subtitle;
}

/// How an add ended.
final class LineupAddOutcome extends EventLineupOutcome {
  const LineupAddOutcome(this.result, {required super.title, super.subtitle});

  final LineupAddResult result;

  @override
  List<Object?> get props => [result, title, subtitle];
}

/// How a removal ended.
final class LineupRemoveOutcome extends EventLineupOutcome {
  const LineupRemoveOutcome(
    this.result, {
    required super.title,
    super.subtitle,
  });

  final LineupRemoveResult result;

  @override
  List<Object?> get props => [result, title, subtitle];
}

/// The lineup of an event, read online and never cached (#519), and the
/// host's write that is out.
final class EventLineupState extends Equatable {
  const EventLineupState({
    this.load = EventLineupLoad.idle,
    this.games = const [],
    this.answered = false,
    this.refreshFailed = false,
    this.refreshing = false,
    this.writing,
    this.outcome,
  });

  final EventLineupLoad load;

  /// Every game of the event's lineup as last read, in the server's order.
  /// Kept through a later failed read, and cleared by a hidden or a gone.
  final List<LineupGame> games;

  /// Whether a read has answered, so [games] are the server's: kept through a
  /// failed read, and cleared by a hidden or a gone.
  final bool answered;

  /// Whether the last read to end failed, so [games] are the last ones read,
  /// possibly stale, or there are none. A read starting does not clear it;
  /// one that ends any other way does. True whenever [load] is failed.
  final bool refreshFailed;

  /// Whether a read the user asked for, with `EventLineupRetryRequested`, is
  /// under way: from the request, before the session is asked, until the
  /// reads it joined have ended. The reads nobody asked for are not narrated.
  final bool refreshing;

  /// The write that is out, until its outcome comes in.
  final LineupWriting? writing;

  /// A write's end the screen announces. Kept until dismissed, replaced, or
  /// cleared as the next write starts.
  final EventLineupOutcome? outcome;

  /// Whether a write is out. A write that arrives meanwhile is ignored.
  bool get busy => writing != null;

  /// This state with the fields given changed. [writing] and [outcome] are
  /// given as a function so each can be set back to null.
  EventLineupState copyWith({
    EventLineupLoad? load,
    List<LineupGame>? games,
    bool? answered,
    bool? refreshFailed,
    bool? refreshing,
    LineupWriting? Function()? writing,
    EventLineupOutcome? Function()? outcome,
  }) => EventLineupState(
    load: load ?? this.load,
    games: games ?? this.games,
    answered: answered ?? this.answered,
    refreshFailed: refreshFailed ?? this.refreshFailed,
    refreshing: refreshing ?? this.refreshing,
    writing: writing == null ? this.writing : writing(),
    outcome: outcome == null ? this.outcome : outcome(),
  );

  @override
  List<Object?> get props => [
    load,
    games,
    answered,
    refreshFailed,
    refreshing,
    writing,
    outcome,
  ];
}

/// The lineup [state] has read, or null when no read has answered (or the
/// bloc isn't there): a caller that must tell an empty lineup from an unknown
/// one asks this.
List<LineupGame>? knownLineup(EventLineupState? state) =>
    state?.answered == true ? state!.games : null;
