import 'dart:async';

import 'package:app_shell/src/servers/registered_servers.dart';
import 'package:app_shell/src/servers/server_activation.dart';
import 'package:app_shell/src/servers/server_list_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

/// The server manager's list (#134): every server registered on this
/// device, with where each stands, and the pick that makes one active.
///
/// It reads the device's registry and the orchestrator, never a server's
/// session, so it works signed out as well as signed in.
///
/// Each row's state is read from the orchestrator whenever the registry,
/// the connected contexts or the active one changes, so a switch made
/// elsewhere, such as by a deep link, moves the in-use marker while the
/// rows keep the registry's order.
class ServerListCubit extends Cubit<ServerListState> {
  ServerListCubit({
    required this._registered,
    required this._orchestrator,
  }) : super(const ServerListLoading()) {
    _listen();
  }

  final RegisteredServers _registered;
  final ServerOrchestrator _orchestrator;
  final BgeLogger _logger = BgeLogger('bge.shell.servers');

  final List<StreamSubscription<Object?>> _subscriptions = [];

  /// The registry's latest list, or null until it answers.
  List<ServerConfig>? _servers;

  /// The server a pick is making active, while it runs.
  String? _switchingTo;

  /// Makes [serverId] active through [activateServer], and says how it went.
  ///
  /// Ignored while another pick runs, for the server already in use, and
  /// while there is no list to pick from. A pick that ends after [close]
  /// still returns its outcome; it just emits nothing.
  Future<ServerPick> pick(String serverId) async {
    if (state is! ServerListReady ||
        _switchingTo != null ||
        _orchestrator.activeServerId == serverId) {
      return const ServerPickIgnored();
    }

    _switchingTo = serverId;
    _publish();
    ServerPick outcome;
    try {
      await activateServer(_orchestrator, serverId);
      outcome = const ServerPickDone();
    } on Object catch (error, stackTrace) {
      _logger.warn(
        'Making a server active from the manager failed',
        error: error,
        stackTrace: stackTrace,
      );
      outcome = ServerPickFailed(error);
    }
    _switchingTo = null;
    _publish();
    return outcome;
  }

  /// Reads the registry again after [ServerListFailed].
  void retry() {
    if (isClosed || state is! ServerListFailed) return;
    emit(const ServerListLoading());
    _listen();
  }

  void _listen() {
    _servers = null;
    _subscriptions.addAll([
      _registered.watch().listen((servers) {
        _servers = servers;
        _publish();
      }, onError: _fail),
      _orchestrator.watchContexts().listen((_) => _publish(), onError: _fail),
      _orchestrator.watchActiveContext().listen(
        (_) => _publish(),
        onError: _fail,
      ),
    ]);
  }

  void _publish() {
    final servers = _servers;
    // A pick can end after the screen that made it has gone.
    if (servers == null || isClosed) return;
    emit(
      ServerListReady(
        rows: [
          for (final server in servers)
            ServerListRow(server: server, state: _stateOf(server.id)),
        ],
        switchingTo: _switchingTo,
      ),
    );
  }

  ServerRowState _stateOf(String serverId) {
    if (_orchestrator.activeServerId == serverId) return ServerRowState.inUse;
    if (_orchestrator.getContext(serverId) != null) {
      return ServerRowState.dormant;
    }
    return ServerRowState.notConnected;
  }

  void _fail(Object error, StackTrace stackTrace) {
    _logger.warn(
      'The server manager could not list the registered servers',
      error: error,
      stackTrace: stackTrace,
    );
    _servers = null;
    unawaited(_cancel());
    if (!isClosed) emit(ServerListFailed(error));
  }

  Future<void> _cancel() async {
    final subscriptions = List.of(_subscriptions);
    _subscriptions.clear();
    await Future.wait(subscriptions.map((s) => s.cancel()));
  }

  @override
  Future<void> close() async {
    await _cancel();
    return super.close();
  }
}

/// How a [ServerListCubit.pick] went.
@immutable
sealed class ServerPick {
  const ServerPick();
}

/// Nothing was done: a switch was already running, the server was already
/// in use, or there was no list.
final class ServerPickIgnored extends ServerPick {
  const ServerPickIgnored();
}

/// The server is now the active one.
final class ServerPickDone extends ServerPick {
  const ServerPickDone();
}

/// Making the server active failed with [error].
final class ServerPickFailed extends ServerPick {
  const ServerPickFailed(this.error);

  final Object error;
}
