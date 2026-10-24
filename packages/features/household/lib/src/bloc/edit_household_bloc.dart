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
/// with, or what an earlier failed save may have changed, and the server's
/// answer cached. Sending a field that did not change would overwrite
/// whatever another device wrote since. Nothing is
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

  /// The fields a failed save sent that the server may hold anyway: its
  /// answer was a success that could not be read, a server failure, or
  /// none at all. [_original] may no longer describe them, so each is sent
  /// on every later submit, changed from it or not: one put back as it was
  /// reverts the server instead of reading as no change.
  final Set<_Field> _maybeSaved = {};

  Future<void> _onSubmitted(
    EditHouseholdSubmitted event,
    Emitter<EditHouseholdState> emit,
  ) async {
    // Saved is final: the form is about to close.
    if (state is EditHouseholdSaved) return;

    final Household answer;
    HouseholdUpdate? update;
    try {
      update = _changes(event);
      // The server answers a patch that names nothing with a 400, and there
      // is nothing to save.
      if (update.isEmpty) {
        emit(EditHouseholdSaved(_original, changed: false));
        return;
      }
      emit(const EditHouseholdSaving());
      answer = await _remote.updateHousehold(_original.id, update);
    } on Object catch (error, stackTrace) {
      emit(EditHouseholdFailed(_failure(error, stackTrace, update)));
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

  /// What [event] changes on [_original], plus whatever [_maybeSaved]
  /// names.
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
    final sendName =
        event.name != _original.name.trim() ||
        _maybeSaved.contains(_Field.name);
    // The form hands over a blank description as null.
    final sendDescription =
        (description ?? '') != originalDescription ||
        _maybeSaved.contains(_Field.description);
    // No choice cannot be sent, so a policy the server may hold stays.
    final sendPolicy =
        policy != null &&
        (policy != _original.settings?.memberInvitePolicy ||
            _maybeSaved.contains(_Field.memberInvitePolicy));
    return HouseholdUpdate(
      name: sendName ? event.name : null,
      description: sendDescription ? description : null,
      clearDescription: sendDescription && description == null,
      memberInvitePolicy: sendPolicy ? policy : null,
    );
  }

  EditHouseholdFailure _failure(
    Object error,
    StackTrace stackTrace,
    HouseholdUpdate? update,
  ) {
    switch (error) {
      // A success this device could not read, whichever variant carries it:
      // the server most likely saved the edit, so the cache is the stale
      // side. Sending it again is harmless, since it sets the same values.
      case HouseholdRemoteException(statusCode: final status?)
          when status >= 200 && status < 300:
        _logger.warn(
          'Household edit answered $status, but could not be read',
          error: error,
          stackTrace: stackTrace,
        );
        _rememberMaybeSaved(update);
        _refresh();
        return EditHouseholdFailure.unexpected;
      case HouseholdRemoteTransientException(:final statusCode):
        // With no answer, or the server's own failure, the edit may have
        // been written before the connection or the server gave out. A 4xx
        // here turned it away first.
        if (statusCode == null || statusCode >= 500) {
          _rememberMaybeSaved(update);
        }
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

  void _rememberMaybeSaved(HouseholdUpdate? update) {
    if (update != null) _maybeSaved.addAll(_Field.sentBy(update));
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

/// A field one [HouseholdUpdate] can carry.
enum _Field {
  name,
  description,
  memberInvitePolicy;

  /// The fields [update] sends, a removed description included.
  static Iterable<_Field> sentBy(HouseholdUpdate update) => [
    if (update.name != null) name,
    if (update.description != null || update.clearDescription) description,
    if (update.memberInvitePolicy != null) memberInvitePolicy,
  ];
}
