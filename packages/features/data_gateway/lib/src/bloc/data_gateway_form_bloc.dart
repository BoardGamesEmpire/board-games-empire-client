import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import '../access/data_gateway_access.dart';
import 'data_gateway_form_event.dart';
import 'data_gateway_form_state.dart';

/// Drives the add and edit forms (#41). One form, two modes: an edit is the
/// add form filled from the row, which sends only the fields that changed.
///
/// An edit reads its row afresh rather than taking it from the list, so a
/// deep link and a web reload open the same form a tap does, and the fields
/// it compares against are the server's current values.
///
/// Refusals reach [access] the way the list's do: a refused read is
/// [DataGatewayFormDenied], and a refused save stops offering the save here
/// and hides the change actions everywhere else for the session.
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
  }

  final DataGatewayRemoteDataSource _remote;
  final DataGatewayAccess? _access;
  final String? _editingId;
  final BgeLogger _logger;

  bool get _mayChange => _access?.value.mayChange ?? true;

  Future<void> _onStarted(
    DataGatewayFormStarted event,
    Emitter<DataGatewayFormState> emit,
  ) async {
    if (_access?.value.read == DataGatewayRead.denied) {
      return emit(const DataGatewayFormDenied());
    }

    final id = _editingId;
    if (id == null) {
      return emit(DataGatewayFormEditing(mayChange: _mayChange));
    }

    emit(const DataGatewayFormLoading());
    try {
      final original = await _remote.fetchOne(id);
      _access?.readGranted();
      emit(DataGatewayFormEditing(original: original, mayChange: _mayChange));
    } on DataGatewayForbiddenException {
      _access?.readDenied();
      emit(const DataGatewayFormDenied());
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
    if (editing is! DataGatewayFormEditing ||
        editing.submitting ||
        !editing.mayChange) {
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
      _access?.changeDenied();
      emit(editing.next(mayChange: false));
    } on DataGatewayNameInUseException {
      emit(editing.next(failure: DataGatewayFormFailure.nameInUse));
    } on DataGatewayNotFoundException {
      emit(editing.next(failure: DataGatewayFormFailure.gone));
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'DataGateway save failed',
        error: error,
        stackTrace: stackTrace,
      );
      emit(editing.next(failure: DataGatewayFormFailure.failed));
    }
  }

  void _onFailureCleared(
    DataGatewayFormFailureCleared event,
    Emitter<DataGatewayFormState> emit,
  ) {
    final editing = state;
    if (editing is! DataGatewayFormEditing || editing.failure == null) return;
    emit(editing.next());
  }
}
