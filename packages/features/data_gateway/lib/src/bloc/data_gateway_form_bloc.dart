import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../access/read_allowed_since.dart';
import 'data_gateway_form_event.dart';
import 'data_gateway_form_state.dart';

/// Drives the add and edit forms (#41). One form, two modes: an edit is the
/// add form filled from the row, which sends only the fields that changed.
///
/// An edit reads its row afresh rather than taking it from the list, so a
/// deep link and a web reload open the same form a tap does, and the fields
/// it compares against are the server's current values.
///
/// ## Access
///
/// The save is offered while the caller's access, as the server answers it,
/// says they may save (#456): create for an add, update for an edit. It
/// follows [access] as its answer changes, up or down, while the form is
/// open. While the answer is unknown, and with no [access] to ask, the form
/// opens read-only and reads as unknown, so it says nothing yet about what
/// the caller's role allows.
///
/// An add whose answer is known and doesn't allow create is
/// [DataGatewayFormDenied], and opens once create is allowed. An edit reads
/// its row whatever the answer, and the server's own answer to that read
/// decides whether it opens.
///
/// A refused read is [DataGatewayFormDenied], and reads again once a changed
/// answer allows read: a refusal can come before the server has written a
/// new user's roles (backend#490). A refused read that comes after such an
/// answer, while the read was out, reads again too, once: no change is left
/// to say so by then. A refused save says why on the form, and
/// does not withdraw the save. Both ask [access] again, and the form follows
/// what it answers. The refusal is the server's word that the
/// answer here may be out of date, as when the caller's role changed since
/// it was asked. A save already in flight runs on, whatever access does
/// meanwhile, and answers for itself.
///
/// An edit's read that succeeds while the answer is still unknown asks
/// [access] again too. The first ask can fail with the server up, as on a
/// 502 from a proxy, and nothing else asks again until a rehydrate trigger.
/// The server has just answered this caller, so an ask now is likely to be
/// answered too.
class DataGatewayFormBloc
    extends Bloc<DataGatewayFormEvent, DataGatewayFormState> {
  DataGatewayFormBloc({
    required this._remote,
    this._access,
    this._editingId,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.data_gateway.form'),
       super(const DataGatewayFormLoading()) {
    on<DataGatewayFormStarted>(_onStarted);
    on<DataGatewayFormSubmitted>(_onSubmitted);
    on<DataGatewayFormFailureCleared>(_onFailureCleared);
    on<DataGatewayFormAccessChanged>(_onAccessChanged);
    _accessChanges = _access?.changes.listen((_) {
      if (!isClosed) add(const DataGatewayFormAccessChanged());
    });
  }

  final DataGatewayRemoteDataSource _remote;
  final CallerAccessRepository? _access;
  final String? _editingId;
  final BgeLogger _logger;
  StreamSubscription<CallerAccess>? _accessChanges;

  /// The access a save needs: create for an add, update for an edit.
  AccessAction get _saveNeeds =>
      _editingId == null ? AccessAction.create : AccessAction.update;

  /// Whether the caller's access lets them save this form now. False while
  /// the answer is unknown, and with no [_access] to ask.
  bool get _maySave =>
      _access?.current.allows(ResourceType.dataGateway, _saveNeeds) ?? false;

  /// Whether the caller's access has answered. False with no [_access] to
  /// ask.
  bool get _accessKnown => _access?.current.isKnown ?? false;

  /// Whether this is an add, and the caller's access is known and doesn't
  /// allow create.
  ///
  /// An add has no read of its own to ask, so it goes by the session's
  /// answer, for as long as it is open. An unknown answer is no refusal: the
  /// add opens read-only until it arrives.
  bool get _addDenied {
    final current = _access?.current;
    return _editingId == null &&
        current != null &&
        current.isKnown &&
        !current.allows(ResourceType.dataGateway, AccessAction.create);
  }

  Future<void> _onStarted(
    DataGatewayFormStarted event,
    Emitter<DataGatewayFormState> emit,
  ) async {
    final id = _editingId;
    if (id == null) {
      if (_addDenied) return emit(const DataGatewayFormDenied());
      return emit(
        DataGatewayFormEditing(maySave: _maySave, accessKnown: _accessKnown),
      );
    }

    final sentUnder = _access?.current;
    emit(const DataGatewayFormLoading());
    try {
      final original = await _remote.fetchOne(id);
      emit(
        DataGatewayFormEditing(
          original: original,
          maySave: _maySave,
          accessKnown: _accessKnown,
        ),
      );
      // The server answered this caller: see Access in the class doc.
      if (_access?.current.isKnown == false) unawaited(_access?.refresh());
    } on DataGatewayForbiddenException {
      unawaited(_access?.refresh());
      emit(const DataGatewayFormDenied());
      // See Access in the class doc.
      if (readAllowedSince(_access, sentUnder) && !isClosed) {
        add(const DataGatewayFormStarted());
      }
    } on DataGatewayNotFoundException {
      emit(const DataGatewayFormMissing());
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'DataGateway read for editing failed',
        error: error,
        stackTrace: stackTrace,
      );
      emit(const DataGatewayFormLoadFailed());
    }
  }

  Future<void> _onSubmitted(
    DataGatewayFormSubmitted event,
    Emitter<DataGatewayFormState> emit,
  ) async {
    final editing = state;
    // Access as it is now, not as the form last showed it: a save it no
    // longer allows is dropped, as from a form built before it fell.
    if (editing is! DataGatewayFormEditing || editing.submitting || !_maySave) {
      return;
    }

    final original = editing.original;
    final changes = original == null
        ? null
        : DataGatewayChanges.between(original, event.input);
    if (changes != null && changes.isEmpty) {
      return emit(editing.next(failure: DataGatewayFormFailure.nothingChanged));
    }

    emit(editing.next(submitting: true));

    try {
      final result = original == null
          ? await _remote.create(event.input)
          : await _remote.update(original.id, changes!);
      emit(DataGatewayFormSaved(result: result, created: original == null));
    } on DataGatewayForbiddenException {
      unawaited(_access?.refresh());
      emit(_unsaved(editing, DataGatewayFormFailure.refused));
    } on DataGatewayNameInUseException {
      emit(_unsaved(editing, DataGatewayFormFailure.nameInUse));
    } on DataGatewayNotFoundException {
      emit(_unsaved(editing, DataGatewayFormFailure.gone));
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'DataGateway save failed',
        error: error,
        stackTrace: stackTrace,
      );
      emit(_unsaved(editing, DataGatewayFormFailure.failed));
    }
  }

  /// [editing] after a save that did not happen. It offers the save again
  /// only if the caller's access still allows it: access that fell while
  /// the save was in flight has withdrawn it, and has closed an add.
  DataGatewayFormState _unsaved(
    DataGatewayFormEditing editing,
    DataGatewayFormFailure failure,
  ) => _addDenied
      ? const DataGatewayFormDenied()
      : editing.next(
          maySave: _maySave,
          accessKnown: _accessKnown,
          failure: failure,
        );

  void _onFailureCleared(
    DataGatewayFormFailureCleared event,
    Emitter<DataGatewayFormState> emit,
  ) {
    final editing = state;
    if (editing is! DataGatewayFormEditing || editing.failure == null) return;
    emit(editing.next());
  }

  /// Keeps the open form in step with the caller's access (#456).
  ///
  /// An add shows access-denied once its answer is known not to allow
  /// create, and opens again once it does. Any form offers the save as its
  /// answer rises and withdraws it as it falls, and says why it has none once
  /// the answer is known. A save already in flight runs on and answers for
  /// itself.
  void _onAccessChanged(
    DataGatewayFormAccessChanged event,
    Emitter<DataGatewayFormState> emit,
  ) {
    final editing = state;
    if (_editingId != null &&
        editing is DataGatewayFormDenied &&
        (_access?.current.allows(ResourceType.dataGateway, AccessAction.read) ??
            false)) {
      // A refused read tries again: see Access in the class doc.
      if (!isClosed) add(const DataGatewayFormStarted());
      return;
    }
    if (_editingId == null) {
      if (editing is DataGatewayFormDenied && !_addDenied) {
        return emit(
          DataGatewayFormEditing(maySave: _maySave, accessKnown: _accessKnown),
        );
      }
      if (editing is DataGatewayFormEditing &&
          !editing.submitting &&
          _addDenied) {
        return emit(const DataGatewayFormDenied());
      }
    }
    final maySave = _maySave;
    final accessKnown = _accessKnown;
    if (editing is! DataGatewayFormEditing ||
        (editing.maySave == maySave && editing.accessKnown == accessKnown)) {
      return;
    }
    // A refused save is answered once access changes: by the form's own
    // reason when the save goes, and by the save itself when it comes back.
    final failure = editing.failure == DataGatewayFormFailure.refused
        ? null
        : editing.failure;
    emit(
      editing.next(
        submitting: editing.submitting,
        maySave: maySave,
        accessKnown: accessKnown,
        failure: failure,
      ),
    );
  }

  @override
  Future<void> close() {
    // Not awaited first, so that the bloc reads as closed from the turn this
    // starts in, as the other DataGateway blocs do.
    unawaited(_accessChanges?.cancel());
    return super.close();
  }
}
