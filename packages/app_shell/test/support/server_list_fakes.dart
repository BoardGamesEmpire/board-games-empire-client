import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bge_test_support/domain.dart';
import 'package:interfaces/orchestration.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

/// A registered server called [displayName], with the id [id].
ServerConfig testRegisteredServer(String id, String displayName) =>
    ServerConfig(
      id: id,
      displayName: displayName,
      serverUrl: testServerUrl,
      connectionState: ConnectionState.disconnected,
      bgeServerId: 'bge-$id',
      cachedIdentity: testServerIdentity(),
      lastIdentityFetchedAt: DateTime.utc(2026, 11, 17),
    );

/// The device's server registry, as the MetaDB watch serves it: each
/// listener gets the current list first, then every change.
class FakeRegisteredServers implements RegisteredServers {
  FakeRegisteredServers([this._servers = const []]);

  List<ServerConfig> _servers;
  final _changes = StreamController<List<ServerConfig>>.broadcast();

  /// The error the next [watch] fails with, once, if any.
  Object? failNextWatch;

  /// How many times [watch] was called.
  int watchCount = 0;

  /// Replaces the registry's list and tells every listener.
  void emit(List<ServerConfig> servers) {
    _servers = servers;
    _changes.add(servers);
  }

  /// Fails every listener's watch with [error].
  void fail(Object error) => _changes.addError(error);

  @override
  Stream<List<ServerConfig>> watch() {
    watchCount++;
    final failure = failNextWatch;
    failNextWatch = null;
    return Stream.multi((listener) {
      if (failure != null) {
        listener.addError(failure);
        return;
      }
      listener.add(_servers);
      final changes = _changes.stream.listen(
        listener.add,
        onError: listener.addError,
      );
      listener.onCancel = changes.cancel;
    });
  }

  Future<void> close() => _changes.close();
}

class _FakeServerContext extends Fake implements ServerContext {}

/// An orchestrator that keeps the connected servers and the active one, and
/// switches or connects the way the real one does once [onActivate] lets it.
class FakeServerOrchestrator extends Fake implements ServerOrchestrator {
  final Map<String, ServerContext> _connected = {};
  final _contexts = StreamController<Map<String, ServerContext>>.broadcast();
  final _active = StreamController<ServerContext?>.broadcast();

  @override
  String? activeServerId;

  /// Every switch and connect asked for, in order, as `switch <id>` or
  /// `connect <id>`.
  final List<String> calls = [];

  /// Runs before a switch or a connect takes effect. A pending future holds
  /// it; a throw fails it.
  Future<void> Function(String serverId)? onActivate;

  /// Connects [serverId] without making it active, and says so.
  void connect(String serverId) {
    _connected[serverId] = _FakeServerContext();
    _contexts.add(Map.of(_connected));
  }

  /// Makes [serverId] active, connecting it first if it isn't, and says so:
  /// a switch made somewhere other than the code under test.
  void activate(String serverId) {
    final context = _connected.putIfAbsent(serverId, _FakeServerContext.new);
    activeServerId = serverId;
    _contexts.add(Map.of(_connected));
    _active.add(context);
  }

  @override
  ServerContext? getContext(String serverId) => _connected[serverId];

  @override
  Stream<Map<String, ServerContext>> watchContexts() => _contexts.stream;

  @override
  Stream<ServerContext?> watchActiveContext() => _active.stream;

  @override
  Future<void> switchActiveServer(String targetServerId) async {
    calls.add('switch $targetServerId');
    await onActivate?.call(targetServerId);
    activate(targetServerId);
  }

  @override
  Future<void> connectServer(String serverId, {bool makeActive = false}) async {
    calls.add('connect $serverId');
    await onActivate?.call(serverId);
    if (makeActive) {
      activate(serverId);
    } else {
      connect(serverId);
    }
  }

  Future<void> close() async {
    await _contexts.close();
    await _active.close();
  }
}
