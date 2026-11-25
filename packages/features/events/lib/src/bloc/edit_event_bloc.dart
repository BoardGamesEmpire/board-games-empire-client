import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:events/src/bloc/edit_event_event.dart';
import 'package:events/src/bloc/edit_event_state.dart';
import 'package:events/src/edit/event_edit_controls.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// Saves an edit of one event's own fields and its rules (#500).
///
/// The edit goes straight to the server, never through the sync queue: one
/// `PATCH` carrying only what changed on the event, then, if the rules
/// changed, one carrying only what changed on them. Sending a field that did
/// not change would overwrite whatever another device wrote since, as the
/// server holds no version to check. Nothing is retried on its own, and a
/// failure leaves the form as typed.
///
/// A submit that changes nothing is saved without asking the session: there
/// is nothing to send. It says the event was updated only when an earlier
/// round of this page saved the details. Otherwise the save is under way
/// from the moment it is asked for, and `confirmSession` is asked before
/// each request goes out, so a page left while the session is checked still
/// waits for the outcome (#464).
///
/// The event goes first. If it fails, the rules are not sent. If it is saved
/// and the rules fail, the fields it carried become the starting point, so
/// the next save sends only the rules. The fields it did not carry keep the
/// values the page opened with, even where the answer differs: another
/// device wrote them, and sending the page's stale ones would overwrite it.
/// The rules are always the last request, and their success ends the edit.
///
/// Each answer is cached before the outcome is emitted. A cache write that
/// throws or declines is logged, and the outcome stands. Rules answered
/// with none to read, for a viewer who may change them but not read them,
/// are saved, with nothing to cache.
///
/// A submit while one is on its way is dropped, so a double tap sends one
/// edit. Saved is final: the page is about to close.
class EditEventBloc extends Bloc<EditEventEvent, EditEventState> {
  EditEventBloc({
    required this._event,
    required this._policy,
    required this._remote,
    required this._repository,
    this._confirmSession,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.events.edit'),
       super(const EditEventEditing()) {
    on<EditEventSubmitted>(_onSubmitted, transformer: droppable());
    on<EditEventEdited>(_onEdited);
  }

  final EventRemoteDataSource _remote;
  final EventRepository _repository;

  /// Asked before anything is sent, as the detail's writes ask it: on web a
  /// sign-in in another tab moves the session to another user (#432). Null,
  /// as on native, is always yes.
  final Future<bool> Function()? _confirmSession;
  final BgeLogger _logger;

  /// The event as the form opened with it, or as the last saved answer
  /// left it. Every submit is diffed against it.
  Event _event;

  /// The rules as the form opened with them. Null when none were cached,
  /// and then none are sent. A save of them ends the edit, so no later
  /// submit is diffed against its answer.
  final EventPolicy? _policy;

  /// The fields a failed send carried that the server may hold anyway: its
  /// answer was a success that could not be read, a server failure, or none
  /// at all. The original may no longer describe them, so each is sent on
  /// every later submit, changed or not, until a send of it lands. One put
  /// back as it was would otherwise read as no change and leave the server's
  /// value. One set spans the event's request and the rules'.
  final Set<EventEditField> _maybeSaved = {};

  /// Whether an earlier send saved the event's own changes. They are then
  /// the starting point, so a later failure of the rules still says the
  /// details were saved, though this round sent none.
  bool _detailsSaved = false;

  Future<void> _onSubmitted(
    EditEventSubmitted event,
    Emitter<EditEventState> emit,
  ) async {
    if (state is EditEventSaved) return;

    final values = event.values;
    final resend = Set<EventEditField>.of(_maybeSaved);
    final eventUpdate = eventUpdateOf(_event, values, resend: resend);
    final rules = values.rules;
    final policy = _policy;
    final policyUpdate = rules != null && policy != null
        ? policyUpdateOf(policy, rules, resend: resend)
        : null;
    final sendEvent = !eventUpdate.isEmpty;
    final sendRules = policyUpdate != null && !policyUpdate.isEmpty;
    // What each request carries: the fields a failure of it may have
    // written, and the ones its success no longer owes.
    final eventFields = fieldsSentBy(eventUpdate);
    final rulesFields = sendRules
        ? rulesFieldsSentBy(policyUpdate)
        : const <EventEditField>{};
    // Whatever stops this submit, an earlier round may have written any of
    // these. A request turned away doesn't undo the other's.
    final carried = {...eventFields, ...rulesFields};

    // The server answers a patch that names nothing with a 400, and there is
    // nothing to save. Details an earlier round saved are still news.
    if (!sendEvent && !sendRules) {
      emit(EditEventSaved(changed: _detailsSaved));
      return;
    }

    // Before the session is asked, so a page left meanwhile keeps the bloc
    // until the save settles, and says how it ended.
    emit(const EditEventSaving());

    if (!await _confirmed()) {
      emit(
        EditEventFailed(
          EditEventFailure.unexpected,
          // A retry of the rules alone still has the details an earlier
          // round saved.
          detailsSaved: _detailsSaved && !sendEvent,
          unsettled: _unsettled(carried),
        ),
      );
      return;
    }

    var out = _Request.event;
    try {
      if (sendEvent) {
        final answer = await _remote.updateEvent(_event.id, eventUpdate);
        _detailsSaved = true;
        await _cache(
          () => _repository.cacheEventRow(answer),
          'Event edit',
        );
        _event = _withSent(_event, answer, eventFields);
        _maybeSaved.removeAll(eventFields);
      }
      if (sendRules) {
        // Asked again: the details' answer may land after a sign-in in
        // another tab, and the rules would go out as that account (#432).
        if (sendEvent && !await _confirmed()) {
          if (isClosed) return;
          emit(
            EditEventFailed(
              EditEventFailure.unexpected,
              detailsSaved: _detailsSaved,
              unsettled: _unsettled(carried),
            ),
          );
          return;
        }
        out = _Request.rules;
        final answer = await _remote.updateEventPolicy(_event.id, policyUpdate);
        // Saved, and ending the edit, whether or not there is one to cache.
        if (answer != null) {
          await _cache(
            () => _repository.cacheEventPolicy(answer),
            'Event rules',
          );
        }
      }
    } on Object catch (error, stackTrace) {
      final sent = switch (out) {
        _Request.event => eventFields,
        _Request.rules => rulesFields,
      };
      // Classified, and so logged, even when the page has closed.
      final failure = _failure(error, stackTrace, sent);
      if (isClosed) return;
      emit(
        EditEventFailed(
          failure,
          detailsSaved: _detailsSaved && out == _Request.rules,
          unsettled: _unsettled(carried),
        ),
      );
      return;
    }
    if (isClosed) return;
    emit(const EditEventSaved());
  }

  /// [base] with the [sent] fields taken from [answer], and the rest left
  /// as [base] has them.
  ///
  /// The answer holds the server's whole event, and another device may have
  /// changed a field this edit never sent. Taking it whole would make the
  /// page's untouched, now stale, field read as a change, and the next save
  /// would send it back over the other device's edit.
  Event _withSent(Event base, Event answer, Set<EventEditField> sent) =>
      base.copyWith(
        title: sent.contains(EventEditField.title) ? answer.title : base.title,
        description: sent.contains(EventEditField.description)
            ? answer.description
            : base.description,
        location: sent.contains(EventEditField.location)
            ? answer.location
            : base.location,
        url: sent.contains(EventEditField.url) ? answer.url : base.url,
        type: sent.contains(EventEditField.type) ? answer.type : base.type,
        reach: sent.contains(EventEditField.reach) ? answer.reach : base.reach,
      );

  /// Whether any of [fields] may be on the server though no send of it
  /// landed, so a failure can't say it wasn't saved.
  bool _unsettled(Set<EventEditField> fields) =>
      fields.any(_maybeSaved.contains);

  /// Whether the session is still the cache's user's. A throw is a no.
  Future<bool> _confirmed() async {
    final confirm = _confirmSession;
    if (confirm == null) return true;
    try {
      final confirmed = await confirm();
      if (!confirmed) {
        _logger.info("Event edit not sent: the session is not this user's");
      }
      return confirmed;
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Event edit not sent: the session could not be checked',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// Runs [write], which caches [what]'s answer, and logs a write that
  /// throws or declines. The server has saved it either way, and the
  /// detail's next read brings it, so the outcome stands.
  Future<void> _cache(Future<bool> Function() write, String what) async {
    try {
      if (!await write()) {
        _logger.info(
          '$what saved, but not cached: the event was not cached, or the '
          'sync queue owns it',
        );
      }
    } on Object catch (error, stackTrace) {
      _logger.warn(
        '$what saved, but its answer was not cached',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// What [error] means for the person, remembering [sent], the fields the
  /// failed request carried, where the server may hold them anyway.
  EditEventFailure _failure(
    Object error,
    StackTrace stackTrace,
    Set<EventEditField> sent,
  ) {
    switch (error) {
      // A success this device could not read, whichever variant carries it:
      // the server most likely saved it. Sending it again sets the same
      // values.
      case EventRemoteException(statusCode: final status?)
          when status >= 200 && status < 300:
        _logger.warn(
          'Event edit answered $status, but could not be read',
          error: error,
          stackTrace: stackTrace,
        );
        _maybeSaved.addAll(sent);
        return EditEventFailure.unexpected;
      case EventRemoteTransientException(statusCode: 401):
        // The server answered, so "offline" is false, and it turned the edit
        // away before writing it. Whether the session is gone is the session
        // signal's call (#484): it re-reads the session and, if the session
        // is gone, signs the user out, which leaves the form.
        _logger.warn(
          'Event edit refused: the session was rejected',
          error: error,
          stackTrace: stackTrace,
        );
        return EditEventFailure.unexpected;
      case EventRemoteTransientException(:final statusCode):
        // With no answer, or the server's own failure, the edit may have
        // been written before the connection or the server gave out. A 4xx
        // turned it away first.
        if (statusCode == null || statusCode >= 500) _maybeSaved.addAll(sent);
        return EditEventFailure.offline;
      case EventWriteRefusedException():
        return EditEventFailure.refused;
      case EventRemoteNotFoundException():
        return EditEventFailure.gone;
      // Read from the code, never the message.
      case EventWriteConflictException(
        code: EventWriteConflictException.policyInvalid,
      ):
        return EditEventFailure.rulesInvalid;
      case EventWriteConflictException():
      case EventRemotePermanentException(statusCode: 400):
        return EditEventFailure.invalid;
      default:
        _logger.warn('Event edit failed', error: error, stackTrace: stackTrace);
        return EditEventFailure.unexpected;
    }
  }

  /// Retires a failure once the form changes. Every edit arrives here; only
  /// one on top of a failure does anything.
  void _onEdited(EditEventEdited event, Emitter<EditEventState> emit) {
    if (state is EditEventFailed) emit(const EditEventEditing());
  }
}

/// Which of a submit's requests is on its way: the event's own fields, then
/// its rules. A failure is about the one that was out.
enum _Request { event, rules }
