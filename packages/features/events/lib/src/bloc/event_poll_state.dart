import 'package:equatable/equatable.dart';
import 'package:events/src/bloc/event_actions_state.dart';
import 'package:models/domain.dart';

/// Where the read of the poll's summary stands (#507).
enum EventPollLoad {
  /// Not read yet.
  idle,

  /// A read is out. One that follows a failed read keeps
  /// [EventPollState.refreshFailed]. One that follows a [hidden] or a [gone]
  /// keeps that load instead, until it answers: the answer it replaces is the
  /// last word on what this viewer may see.
  loading,

  /// The last read was answered.
  loaded,

  /// The last read failed, or the session check stopped it (#432). A
  /// summary read before it is kept.
  failed,

  /// The server won't show this viewer the poll: a 403, as for the roster.
  hidden,

  /// The server has no such event: a 404. A screen that shows the event reads
  /// it again, which finds out for the whole screen.
  gone,
}

/// The availability poll on one event detail screen (#507).
///
/// [refreshFailed] and [refreshing] are the detail's own, as
/// `EventDetailReady` has them: with them a screen keeps its failed banner,
/// and the retry in it, in place while the next read runs, so a retry that
/// has focus keeps it.
final class EventPollState extends Equatable {
  const EventPollState({
    this.load = EventPollLoad.idle,
    this.summary,
    this.pending = const {},
    this.outcome,
    this.refreshFailed = false,
    this.refreshing = false,
  });

  final EventPollLoad load;

  /// The last summary read, kept through a later failed read.
  final AvailabilitySummary? summary;

  /// The viewer's answers sent or waiting to be sent, by occurrence id, shown
  /// over [summary]. Unmodifiable.
  ///
  /// An answer stays until a read that went out after its vote was answered
  /// succeeds, and goes at once when its vote ends in anything but done.
  final Map<String, AvailabilityResponse> pending;

  /// A vote's end the screen announces: never done. Its action is
  /// voteAvailability. Kept until dismissed, replaced, or cleared by the
  /// next tap.
  final EventActionOutcome? outcome;

  /// Whether the last read to end failed, so [summary] is the last one
  /// read, possibly stale, or there is none. A read starting does not clear
  /// it; one that ends any other way does. True whenever [load] is failed.
  final bool refreshFailed;

  /// Whether a read the user asked for, with `EventPollRetryRequested`, is
  /// under way: from the request, before the session is asked, until the
  /// reads it joined have ended. The reads nobody asked for, on open, after
  /// a detail read and after a run of votes, are not narrated.
  final bool refreshing;

  @override
  List<Object?> get props => [
    load,
    summary,
    pending,
    outcome,
    refreshFailed,
    refreshing,
  ];
}
