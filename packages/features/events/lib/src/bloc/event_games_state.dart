import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Where the read of an event's games pool stands (#516).
enum EventGamesLoad {
  /// Not read yet.
  idle,

  /// A read is out. One that follows a failed read keeps
  /// [EventGamesState.refreshFailed]. One that follows a [hidden] or a [gone]
  /// keeps that load instead, until it answers: the answer it replaces is the
  /// last word on what this viewer may see.
  loading,

  /// The last read was answered.
  loaded,

  /// The last read failed, or the session check stopped it (#432). Games
  /// read before it are kept. A read that started in [gone] and answers a
  /// 404 again is failed too, with no games: the event's read didn't settle
  /// it.
  failed,

  /// The server won't show this viewer the pool: a 403 on any attendee's
  /// games.
  hidden,

  /// The server has no such event, or everyone named has left it: a 404. A
  /// screen that shows the event reads it again, which finds out for the
  /// whole screen, and then reads the pool again.
  gone,
}

/// Which of the pool's writes the screen's re-check stopped, in an
/// `EventGamesWriteDropped`: it picks the outcome a dropped write ends with,
/// an [EventOfferOutcome] or an [EventTakeBackOutcome].
enum EventGamesWrite {
  /// A run of offers: the viewer's picks, sent one at a time.
  offer,

  /// Taking one offered game back off the pool.
  takeBack,
}

/// How a run of offers ended (#516).
enum EventOfferResult {
  /// Every pick is on the list, offered now or already.
  done,

  /// Some picks are on the list and some aren't, and the run wasn't stopped.
  partly,

  /// No pick is on the list, and the run wasn't stopped.
  none,

  /// The server refused the write: a 403. The run stops there.
  refused,

  /// Anything else, or the session could not be confirmed as this viewer's
  /// (#432). The run stops there.
  failed,

  /// The screen's own re-check stopped the write, and nothing was sent.
  dropped,
}

/// How a take-back ended (#516).
enum EventTakeBackResult {
  /// The game is off the pool, taken now or already.
  done,

  /// The game still supplies a nomination or a lineup, so it stays on the
  /// pool.
  stillSupplies,

  /// The server refused the write: a 403.
  refused,

  /// Anything else, or the session could not be confirmed as this viewer's
  /// (#432).
  failed,

  /// The screen's own re-check stopped the write, and nothing was sent.
  dropped,
}

/// How a write ended, for the screen to announce: one case per write.
sealed class EventGamesOutcome extends Equatable {
  const EventGamesOutcome();
}

/// How a run of offers ended. [offered] and [notOffered] count its picks, and
/// add up to them; they are zero for a dropped write.
final class EventOfferOutcome extends EventGamesOutcome {
  const EventOfferOutcome({
    required this.result,
    this.offered = 0,
    this.notOffered = 0,
  });

  final EventOfferResult result;

  /// The picks now on the list: offered by this run, or already there.
  final int offered;

  /// Every other pick: skipped, the one that stopped the run, and every pick
  /// after it.
  final int notOffered;

  @override
  List<Object?> get props => [result, offered, notOffered];
}

/// How a take-back ended. [title] names the game it was about, as the event
/// carried it, when there is one.
final class EventTakeBackOutcome extends EventGamesOutcome {
  const EventTakeBackOutcome({required this.result, this.title});

  final EventTakeBackResult result;

  /// The game's title as the event carried it.
  final String? title;

  @override
  List<Object?> get props => [result, title];
}

/// The games pool on one event's Games tab, and the viewer's write that is
/// out (#516).
///
/// [refreshFailed] and [refreshing] are the detail's own, as
/// `EventDetailReady` has them: with them a screen keeps its failed banner,
/// and the retry in it, in place while the next read runs, so a retry that
/// has focus keeps it.
final class EventGamesState extends Equatable {
  const EventGamesState({
    this.load = EventGamesLoad.idle,
    this.games = const [],
    this.sending,
    this.takingBack,
    this.outcome,
    this.refreshFailed = false,
    this.refreshing = false,
  });

  final EventGamesLoad load;

  /// The pool as last read, kept through a later failed read, and cleared by
  /// a hidden or a gone. A game taken back leaves it as the take-back ends.
  final List<OfferedGame> games;

  /// While an offer run is out: how many of its `total` picks have been
  /// settled, offered or not, as `done`. The pick that stops a run isn't
  /// counted.
  final ({int done, int total})? sending;

  /// While a take-back is out: the id of the offered game being taken back.
  final String? takingBack;

  /// A write's end the screen announces. Kept until dismissed, replaced, or
  /// cleared as the next write starts.
  final EventGamesOutcome? outcome;

  /// Whether the last read to end failed, so [games] are the last ones read,
  /// possibly stale, or there are none. A read starting does not clear it;
  /// one that ends any other way does. True whenever [load] is failed.
  final bool refreshFailed;

  /// Whether a read the user asked for, with `EventGamesRetryRequested`, is
  /// under way: from the request, before the session is asked, until the
  /// reads it joined have ended. The reads nobody asked for, on open, after
  /// a detail read and after a write, are not narrated.
  final bool refreshing;

  /// Whether a write is out. An offer, a take-back or a dropped write that
  /// arrives meanwhile is ignored.
  bool get busy => sending != null || takingBack != null;

  /// This state with the fields given changed. [sending], [takingBack] and
  /// [outcome] are given as a function so each can be set back to null.
  EventGamesState copyWith({
    EventGamesLoad? load,
    List<OfferedGame>? games,
    ({int done, int total})? Function()? sending,
    String? Function()? takingBack,
    EventGamesOutcome? Function()? outcome,
    bool? refreshFailed,
    bool? refreshing,
  }) => EventGamesState(
    load: load ?? this.load,
    games: games ?? this.games,
    sending: sending == null ? this.sending : sending(),
    takingBack: takingBack == null ? this.takingBack : takingBack(),
    outcome: outcome == null ? this.outcome : outcome(),
    refreshFailed: refreshFailed ?? this.refreshFailed,
    refreshing: refreshing ?? this.refreshing,
  );

  @override
  List<Object?> get props => [
    load,
    games,
    sending,
    takingBack,
    outcome,
    refreshFailed,
    refreshing,
  ];
}
