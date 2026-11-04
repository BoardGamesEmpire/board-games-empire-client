import 'package:equatable/equatable.dart';
import 'package:network_interface/network_interface.dart';

import '../detail/event_actions.dart';

/// How an action on an event ended (#501, #506, #502).
enum EventActionResult {
  /// The server did it. A delete writes the cache after the outcome is out,
  /// and a date write or a status write before.
  done,

  /// The server has no live event with that id: it was deleted, perhaps by
  /// an earlier delete from this device whose answer was lost (#501). The
  /// cache is written after the outcome is out, as for done.
  ///
  /// For a date write, the date or its event is gone (#506), and for a
  /// status write, the event (#502). Nothing is written, and the read that
  /// follows says what is left.
  gone,

  /// The server refused it with a 403. The outcome's error says how.
  refused,

  /// No answer that says what happened, or the request never went out. The
  /// outcome's error says why, when there is one.
  failed,

  /// A 400: the server judged the write against the date as it now stands
  /// (#506), or a status write against the event's status (#502). A delete
  /// never ends this way.
  changed,

  /// A write of two or more requests that stopped part of the way (#446,
  /// #507): a Confirmed date cancelled, whose remove then failed, or a date
  /// confirmed, whose declines of the other dates didn't all land. A decline
  /// answered 400 or 404 is no miss. The outcome's error is the one the
  /// failed request ended with, and for a confirm the first miss's, which is
  /// null when that miss was a session that said no.
  partlyDone,
}

/// Which of the event's own status writes an outcome is for (#502).
///
/// Cancel and reopen share an [EventAction], as archive and unarchive do,
/// because the server binds each pair to one grant. The outcome's banner
/// needs to tell them apart.
enum EventStatusWrite {
  cancel(EventAction.cancel),
  reopen(EventAction.cancel),
  archive(EventAction.archive),
  unarchive(EventAction.archive);

  const EventStatusWrite(this.action);

  /// The action whose grant the server checks for this write.
  final EventAction action;
}

/// The last event action's outcome, for the detail screen (#501).
final class EventActionOutcome extends Equatable {
  const EventActionOutcome({
    required this.action,
    required this.result,
    this.error,
    this.statusWrite,
  });

  final EventAction action;
  final EventActionResult result;

  /// Which status write this is, for the four that change the event's own
  /// status (#502). Null for every other action.
  final EventStatusWrite? statusWrite;

  /// What the action ended with. Null when it was done, when it failed
  /// before the request went out, when a cancel then remove stopped before
  /// its remove went out, and when a confirm's first missed decline stopped
  /// before it went out.
  final Object? error;

  /// Whether the detail should be read again.
  ///
  /// For the delete: a refusal, or a failure the request itself ended in
  /// that wasn't transient. A refusal says the viewer's role may have
  /// changed on another device, and a failure that isn't transient may have
  /// been a done this device could not read. Done leaves the screen, and
  /// gone has nothing left to read.
  ///
  /// For a date write (#506), every end but a failure: the server derives
  /// the event's status from its dates, and the read brings it, along with
  /// a date that changed or went as it now stands. A failure reads again as
  /// the delete's does, and an add's whatever its error, since a retried
  /// add creates a second date (backend#902): the read shows whether the
  /// first one landed.
  ///
  /// For a status write (#502), as for a date write: done, gone, refused and
  /// changed read again. A done cancel changed the dates it called off, and
  /// the read brings them. Changed is a 400 from a status that moved since
  /// it was read, and the read shows the status as it now stands.
  ///
  /// A failure before the request went out, from a session that no longer
  /// matches or a cache that could not be read, has no error and isn't read
  /// again: nothing reached the server, and a read would ask the same
  /// session.
  ///
  /// For a vote (#507), only changed, gone and refused: the date moved, went,
  /// or the viewer's role changed, and the read shows which. A vote changes
  /// no event status, so a done or failed one reads the poll again, not the
  /// event, and the poll's bloc does that itself once a run of votes ends.
  bool get rereads {
    if (action == EventAction.voteAvailability) {
      return switch (result) {
        EventActionResult.changed ||
        EventActionResult.gone ||
        EventActionResult.refused => true,
        EventActionResult.done ||
        EventActionResult.failed ||
        EventActionResult.partlyDone => false,
      };
    }
    return switch (result) {
      EventActionResult.failed =>
        error != null &&
            (action == EventAction.addDate ||
                error is! EventRemoteTransientException),
      EventActionResult.done ||
      EventActionResult.gone => action != EventAction.delete,
      EventActionResult.refused ||
      EventActionResult.changed ||
      EventActionResult.partlyDone => true,
    };
  }

  @override
  List<Object?> get props => [action, result, error, statusWrite];
}

/// The actions on one event detail screen (#501).
final class EventActionsState extends Equatable {
  const EventActionsState({this.busy = false, this.outcome});

  /// Whether a request is on its way.
  final bool busy;

  /// What the last request answered, until dismissed or replaced.
  final EventActionOutcome? outcome;

  @override
  List<Object?> get props => [busy, outcome];
}
