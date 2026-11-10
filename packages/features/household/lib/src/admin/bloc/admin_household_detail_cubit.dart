import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

import 'admin_household_detail_state.dart';

/// Reads one household for server staff (#685).
///
/// A 404 is [AdminHouseholdDetailGone] and a 403 is
/// [AdminHouseholdDetailRefused], which also asks the caller's access again:
/// the refusal is the server's word that the access the client holds may be
/// out of date. Any other failure is [AdminHouseholdDetailFailed], and
/// [load] tries again. Of two overlapping reads, the one asked for last wins.
class AdminHouseholdDetailCubit extends Cubit<AdminHouseholdDetailState> {
  AdminHouseholdDetailCubit({
    required this._remote,
    required this._id,
    this._access,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.household.admin.detail'),
       super(const AdminHouseholdDetailLoading());

  final AdminHouseholdRemoteDataSource _remote;
  final String _id;
  final CallerAccessRepository? _access;
  final BgeLogger _logger;

  /// Which read is the latest. An older one that answers late is dropped.
  int _readSequence = 0;

  /// Reads the household, showing the loading state until it answers.
  Future<void> load() async {
    final read = ++_readSequence;
    if (state is! AdminHouseholdDetailLoading) {
      emit(const AdminHouseholdDetailLoading());
    }
    AdminHouseholdDetailState next;
    try {
      next = AdminHouseholdDetailReady(await _remote.fetchDetail(_id));
    } on AdminHouseholdNotFoundException {
      next = const AdminHouseholdDetailGone();
    } on AdminHouseholdForbiddenException {
      // Asked even when a newer read superseded this one: the refusal is
      // about the caller, not the household.
      unawaited(_access?.refresh());
      next = const AdminHouseholdDetailRefused();
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Staff household read failed',
        error: error,
        stackTrace: stackTrace,
      );
      next = const AdminHouseholdDetailFailed();
    }
    if (read == _readSequence && !isClosed) emit(next);
  }
}
