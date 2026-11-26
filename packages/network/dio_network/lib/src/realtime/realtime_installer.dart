import 'package:dio_network/src/games/game_search_channel_impl.dart';
import 'package:dio_network/src/realtime/realtime_connection_impl.dart';
import 'package:dio_network/src/realtime/realtime_endpoint.dart';
import 'package:dio_network/src/realtime/socket_manager.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart' show SessionRejectionSignal;
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// Registers the session's [RealtimeConnection] when a user session activates,
/// and the [GameSearchStreamSource] that opens search channels on it (#473).
///
/// It lives in the user scope, so the connection is the session's: the
/// scope's teardown closes it, and the next sign-in, whoever signs in, opens
/// its own with its own credential. Nothing connects here. The first lease
/// does, which for search is a screen opening its channel. The source holds
/// nothing of its own to close.
///
/// The [RealtimeEndpoint] comes from the server scope, which the network
/// installer of each platform fills (`registerServerNetwork`,
/// `registerServerNetworkWeb`), and is reached because the user-scope view
/// falls through to it. A server scope without one gets neither, and a
/// feature does what it does without a socket: search goes over REST.
///
/// The server scope's [SessionRejectionSignal], when it has one, is found the
/// same way and handed to the search source, so a socket's `auth:error`
/// reaches the same session re-read as a REST 401 (#484).
///
/// It never throws or waits, so it may sit anywhere in an installer list.
class RealtimeInstaller implements UserScopeInstaller {
  const RealtimeInstaller({this._managerFactory = socketIoManager});

  /// Builds the connection's socket.io manager. A seam for tests.
  final SocketManagerFactory _managerFactory;

  static final BgeLogger _log = BgeLogger('bge.network.realtime');

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    if (!container.isRegistered<RealtimeEndpoint>()) {
      _log.debug(
        'No realtime endpoint on this server; the session has no socket',
        context: {'serverId': server.serverId},
      );
      return;
    }

    final connection = RealtimeConnectionImpl(
      endpoint: container.get<RealtimeEndpoint>(),
      managerFactory: _managerFactory,
    );
    final sessionRejection = container.isRegistered<SessionRejectionSignal>()
        ? container.get<SessionRejectionSignal>()
        : null;
    container
      ..registerSingleton<RealtimeConnection>(
        connection,
        dispose: (_) => connection.close(),
      )
      ..registerSingleton<GameSearchStreamSource>(
        GameSearchStreamSourceImpl(
          connection,
          sessionRejection: sessionRejection,
        ),
      );
  }
}
