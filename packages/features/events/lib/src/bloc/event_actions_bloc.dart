import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../detail/event_actions.dart';
import 'event_actions_event.dart';
import 'event_actions_state.dart';

/// A cache write an answer calls for, run after its outcome is emitted.
typedef _Write = Future<void> Function();

/// Deletes an event from its detail screen (#501), beside the
/// `EventDetailBloc` that reads it.
///
/// The request goes straight to the server, never through the sync queue
/// (#122): nothing is queued and nothing is retried on its own. An action
/// that can't be undone, firing whenever the device next connects, would
/// surprise the user. So the bloc takes a remote, and the screen offers
/// Delete only when there is one.
///
/// The event's id travels with each request rather than with the bloc. An
/// event created on this device opens on its local id, and the detail bloc
/// follows the sync queue's reconcile to the server's id (#499). By then the
/// screen shows the server's copy and offers Delete, and a bloc fixed to the
/// id it was opened on would send the local id, be answered 404 and report a
/// live event as gone. So the screen sends the id of the detail it shows.
///
/// ## Answers
///
/// | Answer | Cache | Outcome | Detail read again |
/// |---|---|---|---|
/// | 200 | removed | done: the screen leaves | no |
/// | An enveloped 404 | removed | gone: not found | no |
/// | An enveloped 403 | untouched | refused: a banner | yes |
/// | Transient | untouched | failed: a banner, press again | no |
/// | Anything else | untouched | failed | yes |
///
/// [EventActionOutcome.rereads] says which, and the screen starts the read.
///
/// A 200 removes the event for every user on the device
/// ([EventRepository.removeDeletedEvent]): the server deleted it for
/// everyone.
///
/// A 404 is gone, not a failure. A second DELETE of one event answers 404,
/// so a retry after a 200 that was lost would otherwise tell the user a
/// delete that happened had failed. It also makes pressing Delete again
/// after a failure safe. And it removes the event as a 200 does, not as the
/// detail read's 404 forgets it: the server looks among every live event,
/// not only this user's, and nothing restores a deleted one, so the 404 says
/// it is deleted for everyone, and nothing written since can say otherwise.
///
/// A refusal reads the detail again, since the viewer's role may have
/// changed on another device. A failure that isn't transient may have been
/// a delete this device could not read, and the read says which.
///
/// ## Done before the removal
///
/// On a 200 the outcome is emitted before the event is removed. The screen
/// leaves on done, and removing first would make the detail's watch emit
/// null, so the screen would flash not found before it pops. The removal
/// runs on after the screen closes, as the detail read does.
///
/// Closing stops no request. One being handled still sends its DELETE if
/// [close] starts before it goes out, and so does one added in the same turn
/// as [close]: bloc runs its handler before it cancels the emitters, so that
/// request's busy goes out after close has started. A delete the user
/// confirmed is sent. What closing stops is the outcome: an answer that
/// lands once [close] has started emits nothing, but the bloc finishes the
/// write the answer called for, the removal after done or gone. A write that
/// fails is logged, and the outcome stands: the server
/// has answered.
///
/// ## The session
///
/// On web every tab shares one session cookie, and a sign-in in another tab
/// moves it to another user under this screen (#432). So [confirmSession] is
/// asked before the DELETE goes out, as the detail read asks it. A null
/// [confirmSession], as on native, is always yes.
///
/// A no, or a throw, is failed with no error, and isn't read again: nothing
/// reached the server, and a read would ask the same session.
///
/// It isn't asked again before the answer is written, as the detail read's
/// is. That read writes what one user may see, which another user's cache
/// must not take. The removal is every user's: the server deleted the event
/// for everyone, so it holds whoever is signed in now. Skipping it would
/// leave the event cached for each user who could read it, until they open
/// it and are answered 404. A session that has ended takes its repository
/// with it, and the removal's throw is logged as any other.
///
/// ## One at a time
///
/// [EventActionsState.busy] is set before anything is awaited and cleared
/// with the outcome. A request that finds it set is dropped, whatever event
/// it names, so a double tap on the dialog or two quick confirms send one
/// DELETE.
class EventActionsBloc extends Bloc<EventActionsEvent, EventActionsState> {
  EventActionsBloc({
    required this._repository,
    required this._remote,
    this._confirmSession,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.events.actions'),
       super(const EventActionsState()) {
    // The default transformer, which runs requests concurrently. The busy
    // check drops the second of two, so nothing more is needed.
    on<EventDeleteRequested>(_onDeleteRequested);
    on<EventActionOutcomeDismissed>(_onOutcomeDismissed);
  }

  final EventRepository _repository;
  final EventRemoteDataSource _remote;
  final Future<bool> Function()? _confirmSession;
  final BgeLogger _logger;

  /// Set once [close] starts. A request's answer can land after it, and
  /// emits nothing then, though its cache write still runs.
  bool _closing = false;

  Future<void> _onDeleteRequested(
    EventDeleteRequested event,
    Emitter<EventActionsState> emit,
  ) async {
    // Checked and marked before anything is awaited, so a second request,
    // handled while this one waits, finds it busy.
    if (state.busy) return;
    // The last banner described another request, so it goes.
    emit(const EventActionsState(busy: true));

    final (outcome, write) = await _delete(event.eventId);

    // Before the write, so the screen can leave before the removal's null
    // reaches the detail.
    if (!_closing) emit(EventActionsState(outcome: outcome));
    if (write != null) await write();
  }

  /// Sends the delete of [eventId], and answers how it ended and the cache
  /// write the answer calls for, if any. Never throws, and neither does the
  /// write.
  Future<(EventActionOutcome, _Write?)> _delete(String eventId) async {
    if (!await _confirmed('Event delete not sent')) {
      return (_outcome(EventActionResult.failed), null);
    }

    var outcome = _outcome(EventActionResult.done);
    try {
      await _remote.deleteEvent(eventId);
    } on EventRemoteNotFoundException catch (error) {
      _logger.info('Event delete found the event gone', error: error);
      outcome = _outcome(EventActionResult.gone, error);
    } on EventWriteRefusedException catch (error) {
      _logger.info('Event delete refused', error: error);
      return (_outcome(EventActionResult.refused, error), null);
    } on Object catch (error, stackTrace) {
      _logger.warn('Event delete failed', error: error, stackTrace: stackTrace);
      return (_outcome(EventActionResult.failed, error), null);
    }

    // Done and gone alike: the server has no live event with this id, for
    // any user, so the session isn't asked again (above).
    return (outcome, () => _remove(eventId));
  }

  EventActionOutcome _outcome(EventActionResult result, [Object? error]) =>
      EventActionOutcome(
        action: EventAction.delete,
        result: result,
        error: error,
      );

  /// Whether the session is still this cache's user's: [confirmSession] said
  /// yes, or there is none to ask. A no is logged, as is a throw, each
  /// saying what [stopped].
  Future<bool> _confirmed(String stopped) async {
    final confirm = _confirmSession;
    if (confirm == null) return true;

    final bool confirmed;
    try {
      confirmed = await confirm();
    } on Object catch (error, stackTrace) {
      _logger.warn(
        '$stopped: the session could not be checked',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
    if (!confirmed) {
      _logger.info(
        "$stopped: the session could not be confirmed as this user's",
      );
    }
    return confirmed;
  }

  /// Removes [eventId], which the server deleted, from the cache.
  Future<void> _remove(String eventId) async {
    try {
      if (!await _repository.removeDeletedEvent(eventId)) {
        _logger.info(
          'Event deleted, but not removed from the cache: none was cached, '
          'or the sync queue owns it',
        );
      }
    } on Object catch (error, stackTrace) {
      // The server deleted it all the same. It stays cached until a hydrate
      // or a read finds it gone.
      _logger.warn(
        'Event deleted, but not removed from the cache',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _onOutcomeDismissed(
    EventActionOutcomeDismissed event,
    Emitter<EventActionsState> emit,
  ) {
    if (state.outcome == null) return;
    emit(EventActionsState(busy: state.busy));
  }

  @override
  Future<void> close() {
    _closing = true;
    return super.close();
  }
}
