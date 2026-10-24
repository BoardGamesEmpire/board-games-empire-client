import 'dart:async';

import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'edit_household_event.dart';
import 'edit_household_state.dart';

/// Saves an edit of one household's name, description and member invite
/// policy (#476).
///
/// The edit goes straight to the server, never through the sync queue: one
/// `PATCH` carrying only what changed from the household the form opened
/// with, and the server's answer cached. Sending a field that did not
/// change would overwrite whatever another device wrote since. Nothing is
/// retried on its own, and a failure leaves the form as typed.
///
/// A submit while one is on its way is dropped, so a double tap sends one
/// edit.
class EditHouseholdBloc extends Bloc<EditHouseholdEvent, EditHouseholdState> {
  EditHouseholdBloc({
    required this._original,
    required this._remote,
    required this._repository,
    this._onRefresh,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.household.edit'),
       super(const EditHouseholdEditing()) {
    on<EditHouseholdSubmitted>(_onSubmitted, transformer: droppable());
    on<EditHouseholdEdited>(_onEdited);
  }

  /// The household as the form opened with it. Every submit is diffed
  /// against it.
  final Household _original;
  final HouseholdRemoteDataSource _remote;
  final HouseholdRepository _repository;

  /// Reads the user's households again. Started, never awaited, after an
  /// answer that says the cached household is out of date.
  final Future<void> Function()? _onRefresh;
  final BgeLogger _logger;

  Future<void> _onSubmitted(
    EditHouseholdSubmitted event,
    Emitter<EditHouseholdState> emit,
  ) async {
    // Saved is final: the form is about to close.
    if (state is EditHouseholdSaved) return;

    final Household answer;
    try {
      final update = _changes(event);
      // The server answers a patch that names nothing with a 400, and there
      // is nothing to save.
      if (update.isEmpty) {
        emit(EditHouseholdSaved(_original, changed: false));
        return;
      }
      emit(const EditHouseholdSaving());
      answer = await _remote.updateHousehold(_original.id, update);
    } on Object catch (error, stackTrace) {
      emit(EditHouseholdFailed(_failure(error, stackTrace)));
      return;
    }

    try {
      await _repository.cacheHousehold(answer);
    } on Object catch (error, stackTrace) {
      // The server accepted the edit, and the next hydrate brings it.
      _logger.warn(
        'Household edit saved, but its answer was not cached',
        error: error,
        stackTrace: stackTrace,
      );
    }
    emit(EditHouseholdSaved(answer));
  }

  /// What [event] changes on [_original].
  ///
  /// The form trims what it hands over, and the server stores a name or
  /// description as it was sent, so another client may have left
  /// whitespace around one. The original is compared trimmed too, or an
  /// untouched field would read as changed and be sent back over whatever
  /// was written since.
  HouseholdUpdate _changes(EditHouseholdSubmitted event) {
    final description = event.description;
    final policy = event.memberInvitePolicy;
    final originalDescription = _original.description?.trim() ?? '';
    return HouseholdUpdate(
      name: event.name == _original.name.trim() ? null : event.name,
      description: description == null || description == originalDescription
          ? null
          : description,
      clearDescription: description == null && originalDescription.isNotEmpty,
      memberInvitePolicy: policy == _original.settings?.memberInvitePolicy
          ? null
          : policy,
    );
  }

  EditHouseholdFailure _failure(Object error, StackTrace stackTrace) {
    switch (error) {
      case HouseholdRemoteTransientException():
        return EditHouseholdFailure.offline;
      case HouseholdNotFoundException():
        // The refresh, not this answer, removes it from the cache.
        _refresh();
        return EditHouseholdFailure.gone;
      case HouseholdRemotePermanentException(statusCode: 403):
        // The viewer's role may have changed on another device.
        _refresh();
        return EditHouseholdFailure.refused;
      case HouseholdRemotePermanentException(statusCode: 400):
        return EditHouseholdFailure.invalid;
      default:
        _logger.warn(
          'Household edit failed',
          error: error,
          stackTrace: stackTrace,
        );
        return EditHouseholdFailure.unexpected;
    }
  }

  void _refresh() {
    final onRefresh = _onRefresh;
    if (onRefresh == null) return;
    unawaited(_runRefresh(onRefresh));
  }

  Future<void> _runRefresh(Future<void> Function() onRefresh) async {
    try {
      await onRefresh();
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Household refresh after an edit failed',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Retires a failure once the form changes. Every edit arrives here; only
  /// one on top of a failure does anything.
  void _onEdited(EditHouseholdEdited event, Emitter<EditHouseholdState> emit) {
    if (state is EditHouseholdFailed) emit(const EditHouseholdEditing());
  }
}
