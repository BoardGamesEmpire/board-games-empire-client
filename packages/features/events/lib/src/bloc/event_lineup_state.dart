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

/// The lineup of an event, read online and never cached (#519).
final class EventLineupState extends Equatable {
  const EventLineupState({
    this.load = EventLineupLoad.idle,
    this.games = const [],
    this.answered = false,
    this.refreshFailed = false,
    this.refreshing = false,
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

  /// This state with the fields given changed.
  EventLineupState copyWith({
    EventLineupLoad? load,
    List<LineupGame>? games,
    bool? answered,
    bool? refreshFailed,
    bool? refreshing,
  }) => EventLineupState(
    load: load ?? this.load,
    games: games ?? this.games,
    answered: answered ?? this.answered,
    refreshFailed: refreshFailed ?? this.refreshFailed,
    refreshing: refreshing ?? this.refreshing,
  );

  @override
  List<Object?> get props => [load, games, answered, refreshFailed, refreshing];
}

/// The lineup [state] has read, or null when no read has answered (or the
/// bloc isn't there): a caller that must tell an empty lineup from an unknown
/// one asks this.
List<LineupGame>? knownLineup(EventLineupState? state) =>
    state?.answered == true ? state!.games : null;
