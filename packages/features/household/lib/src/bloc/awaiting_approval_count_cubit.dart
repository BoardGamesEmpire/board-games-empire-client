import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// How many of a household's invites await approval (#489), for the
/// invites entry on the household screen.
///
/// Null until a read succeeds, and again after one fails: a count that may
/// be out of date is not shown. The read asks for one row and takes the
/// page's total, which the server counts with the rows. Of two overlapping
/// reads, the one asked for last wins, whichever answers first.
class AwaitingApprovalCountCubit extends Cubit<int?> {
  AwaitingApprovalCountCubit({
    required this._householdId,
    required this._remote,
    BgeLogger? logger,
  }) : _logger = logger ?? BgeLogger('bge.household.invites.awaiting'),
       super(null);

  final String _householdId;
  final HouseholdInviteRemoteDataSource _remote;
  final BgeLogger _logger;

  /// Which read is the latest. An older one that answers late is dropped.
  int _readSequence = 0;

  /// Reads the count again.
  Future<void> load() async {
    final read = ++_readSequence;
    int? count;
    try {
      final page = await _remote.fetchHouseholdInvites(
        _householdId,
        status: HouseholdInviteStatus.awaitingApproval,
        limit: 1,
      );
      count = page.meta.total;
    } on Object catch (error, stackTrace) {
      if (read != _readSequence) return;
      _logger.warn(
        'Could not count the invites awaiting approval',
        error: error,
        stackTrace: stackTrace,
      );
    }
    if (read == _readSequence && !isClosed) emit(count);
  }
}
