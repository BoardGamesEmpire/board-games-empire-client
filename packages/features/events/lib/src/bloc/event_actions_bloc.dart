import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../detail/event_actions.dart';
import 'event_actions_event.dart';
import 'event_actions_state.dart';

/// A cache write a delete's answer calls for, run after its outcome is
/// emitted.
typedef _Write = Future<void> Function();

/// Deletes an event from its detail screen (#501), and adds, changes and
/// removes its dates (#506), beside the `EventDetailBloc` that reads it.
///
/// Each request goes straight to the server, never through the sync queue
/// (#122, #527): nothing is queued and nothing is retried on its own. An
/// action that can't be undone, firing whenever the device next connects,
/// would surprise the user. So the bloc takes a remote, and the screen
/// offers these actions only when there is one.
///
/// The event's id travels with each request rather than with the bloc. An
/// event created on this device opens on its local id, and the detail bloc
/// follows the sync queue's reconcile to the server's id (#499). By then the
/// screen shows the server's copy and offers Delete, and a bloc fixed to the
/// id it was opened on would send the local id, be answered 404 and report a
/// live event as gone. So the screen sends the id of the detail it shows,
/// for a date write as for the delete.
///
/// ## The delete's answers
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
/// ## Dates
///
/// The six date writes (#506) share one runner. Each asks the session,
/// sends one request, writes what the server answered into the cache, and
/// emits how it ended. The screen shows that as a banner, and reads the
/// event again where [EventActionOutcome.rereads] says so. The server
/// derives the event's status from its dates, so the read is how the
/// status follows a write.
///
/// | Answer | Outcome | Detail read again |
/// |---|---|---|
/// | 2xx | done: the answer written, then read | yes |
/// | An enveloped 400, one message | changed: the date as it is now | yes |
/// | An enveloped 404 | gone: the date or the event | yes |
/// | An enveloped 403 | refused, as for the delete | yes |
/// | A sent add that failed | failed | yes, before Add is pressed again |
/// | Other transient | failed: press again | no |
/// | Anything else | failed | yes |
///
/// Done writes the cache: the date the server answered with, or, for a
/// remove, the cached date removed. A cancel-then-remove writes the cancelled
/// date before its remove goes out, so its partlyDone, or a remove's gone,
/// follows a cache write. Every other end leaves the cache to the read.
/// After a 404 that read is answered 404 too when the event is gone, and
/// forgets it (#498).
///
/// A 400 isn't read for its code. A date that moved since it was read, a
/// retry of a write that landed (backend#901), a cancelled event
/// (backend#795) and a Fixed event's second date all answer it, and each
/// has the same fix: show the date as it now stands. A 400 for a value the
/// server's validation refused is failed, not changed: the remote reads it
/// as permanent, since the same request is refused again.
///
/// A failed add is read again even when the failure is transient, because a
/// retried add creates a second date (backend#902). An add whose answer was
/// lost may have landed, and the read shows it before Add can be pressed
/// again.
///
/// ### Written before the outcome
///
/// Unlike the delete's removal, a date's answer is written before its
/// outcome is emitted. The outcome starts the screen's read, and a write
/// that landed after the read's newer copy would put the older date back.
/// The screen stays, so there is no flash to avoid.
///
/// The session isn't asked again before the write. The returned date is the
/// server's, the same for every user who can read the event, and
/// [EventRepository.cacheOccurrence] grants no access: it writes beside an
/// event already cached, or not at all. A write that declines or throws is
/// logged, and the outcome stands, as for the delete's removal.
///
/// Closing works as for the delete: a request is sent, and an answer that
/// lands once [close] has started is still written, but emits nothing.
///
/// ### Cancel, then remove
///
/// The server removes a Confirmed date only once it is cancelled (#446), so
/// [EventDateRemoveRequested.cancelFirst] sends two requests under one busy
/// state. It asks the session, sends the cancel, and writes the Cancelled
/// date it is answered with. Then it asks the session again, since each
/// write goes out with the session checked first (#432), and sends the
/// remove.
///
/// A cancel that isn't done ends there with its own outcome, and the remove
/// isn't sent. A 400 there is changed, as anywhere: the date may have been
/// cancelled elsewhere, and the read shows it offering a plain Remove. A
/// remove answered 404 is gone, since no date is left to remove. Any other
/// end to the remove, a session that said no included, is partlyDone: the
/// date stays Cancelled, and the read offers Remove again. Both requests
/// report as [EventAction.removeDate].
///
/// ## The session
///
/// On web every tab shares one session cookie, and a sign-in in another tab
/// moves it to another user under this screen (#432). So [confirmSession] is
/// asked before each request goes out, as the detail read asks it. A null
/// [confirmSession], as on native, is always yes.
///
/// A no, or a throw, is failed with no error, and isn't read again: nothing
/// reached the server, and a read would ask the same session. A cancel then
/// remove whose cancel was done is the exception, above.
///
/// It isn't asked again before the answer is written, as the detail read's
/// is. That read writes what one user may see, which another user's cache
/// must not take. The removal is every user's: the server deleted the event
/// for everyone, so it holds whoever is signed in now. Skipping it would
/// leave the event cached for each user who could read it, until they open
/// it and are answered 404. A session that has ended takes its repository
/// with it, and the removal's throw is logged as any other. A date's answer
/// is every user's in the same way, above.
///
/// ## One at a time
///
/// [EventActionsState.busy] is set before anything is awaited and cleared
/// with the outcome. A request that finds it set is dropped, whatever it
/// asks for and whichever event it names, so a double tap on a dialog or two
/// quick confirms send one request. A cancel then remove holds it through
/// both of its requests.
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
    on<EventDateAddRequested>(_onDateAddRequested);
    on<EventDateEditRequested>(_onDateEditRequested);
    on<EventDateConfirmRequested>(_onDateConfirmRequested);
    on<EventDateDeclineRequested>(_onDateDeclineRequested);
    on<EventDateCancelRequested>(_onDateCancelRequested);
    on<EventDateRemoveRequested>(_onDateRemoveRequested);
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

  Future<void> _onDateAddRequested(
    EventDateAddRequested event,
    Emitter<EventActionsState> emit,
  ) => _runDate(
    emit,
    () => _sendDate(
      EventAction.addDate,
      'Date add',
      () => _remote.addOccurrence(
        event.eventId,
        event.draft,
        sortOrder: event.sortOrder,
      ),
      _repository.cacheOccurrence,
    ),
  );

  Future<void> _onDateEditRequested(
    EventDateEditRequested event,
    Emitter<EventActionsState> emit,
  ) => _runDate(
    emit,
    () => _sendDate(
      EventAction.editDate,
      'Date edit',
      () => _remote.updateOccurrence(
        event.eventId,
        event.occurrenceId,
        event.update,
      ),
      _repository.cacheOccurrence,
    ),
  );

  Future<void> _onDateConfirmRequested(
    EventDateConfirmRequested event,
    Emitter<EventActionsState> emit,
  ) => _runDate(
    emit,
    () => _sendDate(
      EventAction.confirmDate,
      'Date confirm',
      () => _remote.confirmOccurrence(event.eventId, event.occurrenceId),
      _repository.cacheOccurrence,
    ),
  );

  Future<void> _onDateDeclineRequested(
    EventDateDeclineRequested event,
    Emitter<EventActionsState> emit,
  ) => _runDate(
    emit,
    () => _sendDate(
      EventAction.declineDate,
      'Date decline',
      () => _remote.declineOccurrence(event.eventId, event.occurrenceId),
      _repository.cacheOccurrence,
    ),
  );

  Future<void> _onDateCancelRequested(
    EventDateCancelRequested event,
    Emitter<EventActionsState> emit,
  ) => _runDate(
    emit,
    () => _sendDate(
      EventAction.cancelDate,
      'Date cancel',
      () => _remote.cancelOccurrence(
        event.eventId,
        event.occurrenceId,
        reason: event.reason,
      ),
      _repository.cacheOccurrence,
    ),
  );

  Future<void> _onDateRemoveRequested(
    EventDateRemoveRequested event,
    Emitter<EventActionsState> emit,
  ) => _runDate(
    emit,
    () => event.cancelFirst ? _cancelThenRemove(event) : _removeDate(event),
  );

  /// Runs [write], which sends a date's requests and never throws, and
  /// emits the outcome it answers. The busy check and closing work as for
  /// the delete.
  Future<void> _runDate(
    Emitter<EventActionsState> emit,
    Future<EventActionOutcome> Function() write,
  ) async {
    // Checked and marked before anything is awaited, as for the delete.
    if (state.busy) return;
    emit(const EventActionsState(busy: true));

    final outcome = await write();

    // After the cache write, which must land before the read the outcome
    // starts.
    if (!_closing) emit(EventActionsState(outcome: outcome));
  }

  /// Cancels the Confirmed date [event] names, then removes it if the
  /// cancel was done (#446). Never throws.
  Future<EventActionOutcome> _cancelThenRemove(
    EventDateRemoveRequested event,
  ) async {
    final cancelled = await _sendDate(
      EventAction.removeDate,
      'Date cancel before its remove',
      () => _remote.cancelOccurrence(
        event.eventId,
        event.occurrenceId,
        reason: event.reason,
      ),
      _repository.cacheOccurrence,
    );
    if (cancelled.result != EventActionResult.done) return cancelled;

    final removed = await _removeDate(event);
    return switch (removed.result) {
      EventActionResult.done || EventActionResult.gone => removed,
      // The cancel landed and the remove didn't come back done: a remove
      // lost in transit may have landed, so the read says whether the date
      // is still there. If it is, it stays Cancelled, which offers Remove
      // again.
      EventActionResult.refused ||
      EventActionResult.failed ||
      EventActionResult.changed ||
      EventActionResult.partlyDone => EventActionOutcome(
        action: EventAction.removeDate,
        result: EventActionResult.partlyDone,
        error: removed.error,
      ),
    };
  }

  /// Removes the date [event] names, as it stands. Never throws.
  Future<EventActionOutcome> _removeDate(EventDateRemoveRequested event) =>
      _sendDate(
        EventAction.removeDate,
        'Date remove',
        () => _remote.removeOccurrence(event.eventId, event.occurrenceId),
        (_) => _repository.removeCachedOccurrence(
          eventId: event.eventId,
          occurrenceId: event.occurrenceId,
        ),
      );

  /// Sends one date write with [send], once the session says yes, and
  /// writes what it answered to the cache with [cache]. Answers how it
  /// ended, as [action], and logs it under [request]. Never throws.
  Future<EventActionOutcome> _sendDate<T>(
    EventAction action,
    String request,
    Future<T> Function() send,
    Future<bool> Function(T answer) cache,
  ) async {
    EventActionOutcome ended(EventActionResult result, [Object? error]) =>
        EventActionOutcome(action: action, result: result, error: error);

    if (!await _confirmed('$request not sent')) {
      return ended(EventActionResult.failed);
    }

    final T answer;
    try {
      answer = await send();
    } on EventWriteConflictException catch (error) {
      _logger.info('$request refused for the date as it is now', error: error);
      return ended(EventActionResult.changed, error);
    } on EventRemoteNotFoundException catch (error) {
      _logger.info('$request found the date or its event gone', error: error);
      return ended(EventActionResult.gone, error);
    } on EventWriteRefusedException catch (error) {
      _logger.info('$request refused', error: error);
      return ended(EventActionResult.refused, error);
    } on Object catch (error, stackTrace) {
      _logger.warn('$request failed', error: error, stackTrace: stackTrace);
      return ended(EventActionResult.failed, error);
    }

    // Before the outcome, and without asking the session again: the date is
    // the server's for everyone who can read the event (above).
    await _cacheDate(request, () => cache(answer));
    return ended(EventActionResult.done);
  }

  /// Runs [write], the cache write a date write's answer calls for. One that
  /// declines or throws is logged, and the outcome stands: the server has
  /// answered.
  Future<void> _cacheDate(String request, Future<bool> Function() write) async {
    try {
      if (!await write()) {
        _logger.info(
          '$request done, but not written to the cache: the event or the '
          'date is not cached, or the sync queue owns the event',
        );
      }
    } on Object catch (error, stackTrace) {
      // The server has it all the same, and the read the outcome starts
      // brings it, if the cache can take it.
      _logger.warn(
        '$request done, but not written to the cache',
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
