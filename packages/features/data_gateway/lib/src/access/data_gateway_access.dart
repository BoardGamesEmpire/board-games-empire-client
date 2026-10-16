import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// Whether the signed-in user may read DataGateways on this server.
enum DataGatewayRead {
  /// Not known yet, or the last read failed for a reason that says nothing
  /// about the role.
  unknown,
  granted,
  denied,
}

/// What this session has learned about the user's access to DataGateways
/// (#41).
final class DataGatewayAccessState extends Equatable {
  const DataGatewayAccessState({
    this.read = DataGatewayRead.unknown,
    this.mayChange = true,
  });

  final DataGatewayRead read;

  /// False once a change has been refused with a 403, for the rest of the
  /// session.
  ///
  /// True until then, because nothing tells a reader who may change
  /// DataGateways (Owner, Admin) from one who may not (Moderator) before they
  /// try. #456 replaces this with the caller's abilities, once backend#757
  /// exposes them.
  final bool mayChange;

  @override
  List<Object?> get props => [read, mayChange];
}

/// The session's answer to "may this user see and change DataGateways?"
/// (#41).
///
/// The server has no route that says what a caller may do, and `user.role`
/// names an admin only for the server's first human. So the answer is learned
/// from the API's own refusals:
///
/// - [check] reads one row. A 200 grants the read, and the home drawer offers
///   the admin entry; a 403 denies it, and the entry stays hidden.
/// - A screen that reads the list reports what it found the same way, so a
///   deep link keeps this in step with what the user actually saw.
/// - The first 403 on a change calls [changeDenied], which hides every change
///   action until the session ends.
///
/// Registered per user session by [DataGatewayAccessInstaller], so a sign-out
/// discards it and the next user starts from unknown.
class DataGatewayAccess implements ValueListenable<DataGatewayAccessState> {
  DataGatewayAccess({required this._remote, BgeLogger? logger})
    : _logger = logger ?? BgeLogger('bge.data_gateway.access');

  final DataGatewayRemoteDataSource _remote;
  final BgeLogger _logger;
  final ValueNotifier<DataGatewayAccessState> _state = ValueNotifier(
    const DataGatewayAccessState(),
  );

  Future<void>? _checking;
  bool _disposed = false;

  @override
  DataGatewayAccessState get value => _state.value;

  @override
  void addListener(VoidCallback listener) => _state.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _state.removeListener(listener);

  /// Whether a [check] is in flight.
  bool get isChecking => _checking != null;

  /// Reads one row to learn whether the user may read DataGateways.
  ///
  /// Never throws. A failure that is not a 403 leaves the answer as it was:
  /// an unreachable server says nothing about the role, and an entry already
  /// shown should not vanish over a dropped connection. Calls made while one
  /// is in flight join it.
  Future<void> check() =>
      _checking ??= _check().whenComplete(() => _checking = null);

  Future<void> _check() async {
    try {
      await _remote.fetchPage(limit: 1);
      readGranted();
    } on DataGatewayForbiddenException {
      readDenied();
    } on Object catch (error, stackTrace) {
      _logger.info(
        'Could not learn whether this user may read DataGateways',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// A read of DataGateways succeeded.
  void readGranted() => _emit(
    DataGatewayAccessState(
      read: DataGatewayRead.granted,
      mayChange: value.mayChange,
    ),
  );

  /// A read of DataGateways was refused.
  ///
  /// Says nothing about changes: every screen that offers one shows its
  /// access-denied state instead, and a user let in later in the session
  /// (their role was raised) should find the change actions there.
  void readDenied() => _emit(
    DataGatewayAccessState(
      read: DataGatewayRead.denied,
      mayChange: value.mayChange,
    ),
  );

  /// A change to a DataGateway was refused. Lasts for the session.
  void changeDenied() =>
      _emit(DataGatewayAccessState(read: value.read, mayChange: false));

  void _emit(DataGatewayAccessState next) {
    // A check can land after the session that owns this has ended.
    if (_disposed) return;
    _state.value = next;
  }

  void dispose() {
    _disposed = true;
    _state.dispose();
  }
}
