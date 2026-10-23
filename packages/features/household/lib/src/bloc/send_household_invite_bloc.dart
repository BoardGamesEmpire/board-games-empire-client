import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'send_household_invite_event.dart';
import 'send_household_invite_state.dart';

/// Sends one invite to a household (#455).
///
/// A submit while one is on its way is dropped, so a double tap sends one
/// invite. Nothing is retried on its own: a send the server never answered
/// may still have created the invite, and sending it again would be refused
/// as a duplicate or count twice against the daily limit.
class SendHouseholdInviteBloc
    extends Bloc<SendHouseholdInviteEvent, SendHouseholdInviteState> {
  SendHouseholdInviteBloc({
    required this._householdId,
    required this._remote,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.household.invites.send'),
       super(const SendHouseholdInviteEditing()) {
    on<SendHouseholdInviteSubmitted>(_onSubmitted, transformer: droppable());
    on<SendHouseholdInviteEdited>(_onEdited);
  }

  final String _householdId;
  final HouseholdInviteRemoteDataSource _remote;
  final BgeLogger _logger;

  Future<void> _onSubmitted(
    SendHouseholdInviteSubmitted event,
    Emitter<SendHouseholdInviteState> emit,
  ) async {
    // Sent is final: the form is about to close.
    if (state is SendHouseholdInviteSent) return;

    emit(const SendHouseholdInviteSending());
    try {
      emit(
        SendHouseholdInviteSent(await _remote.send(_householdId, event.draft)),
      );
    } on Object catch (error, stackTrace) {
      if (error is! HouseholdInviteRefusedException) {
        _logger.warn(
          'Household invite send failed',
          error: error,
          stackTrace: stackTrace,
        );
      }
      emit(SendHouseholdInviteFailed(error));
    }
  }

  /// Retires a failure once the form changes. Every edit arrives here; only
  /// one on top of a failure does anything.
  void _onEdited(
    SendHouseholdInviteEdited event,
    Emitter<SendHouseholdInviteState> emit,
  ) {
    if (state is SendHouseholdInviteFailed) {
      emit(const SendHouseholdInviteEditing());
    }
  }
}
