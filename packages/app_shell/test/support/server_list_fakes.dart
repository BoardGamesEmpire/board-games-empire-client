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
/// switches or connects the way the real one does once [onActivate] lets it,
/// and adds once [onAdd] does. A switch away from a server runs
/// [onBackground] for it, where a test ends what the real one ends.
class FakeServerOrchestrator extends Fake implements ServerOrchestrator {
  final Map<String, ServerContext> _connected = {};
  final _contexts = StreamController<Map<String, ServerContext>>.broadcast();
  final _active = StreamController<ServerContext?>.broadcast();

  @override
  String? activeServerId;

  /// Every add, switch and connect asked for, in order, as `add <id>`,
  /// `switch <id>` or `connect <id>`.
  final List<String> calls = [];

  /// Runs before a switch or a connect takes effect. A pending future holds
  /// it; a throw fails it.
  Future<void> Function(String serverId)? onActivate;

  /// Runs for the server a switch, a connect or an add leaves, once the
  /// target is ready and before it becomes active, as the real orchestrator
  /// backgrounds the server it leaves. The real context's `background()`
  /// ends that server's user session (#135), which nothing in this fake
  /// does unless a test does it here.
  Future<void> Function(String serverId)? onBackground;

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
    final leaving = _leave(targetServerId);
    if (leaving != null) await leaving;
    activate(targetServerId);
  }

  /// Backgrounds the active server, if [targetServerId] replaces it. Null
  /// when there is nothing to run, so a test with no [onBackground] sees the
  /// same turns it always did.
  Future<void>? _leave(String targetServerId) {
    final leaving = activeServerId;
    if (leaving == null || leaving == targetServerId) return null;
    return onBackground?.call(leaving);
  }

  /// Runs as a server is added, with its id and display name, before it
  /// becomes active. A throw fails the add, as a duplicate does.
  FutureOr<void> Function(String serverId, String displayName)? onAdd;

  /// Adds a server whose id is `local-<bgeServerId>` and makes it active,
  /// as the real one does once [onAdd] lets it.
  @override
  Future<String> addAndActivateServer({
    required String displayName,
    required String serverUrl,
    required String bgeServerId,
    required ServerIdentity identity,
  }) async {
    final serverId = 'local-$bgeServerId';
    calls.add('add $serverId');
    await onAdd?.call(serverId, displayName);
    final leaving = _leave(serverId);
    if (leaving != null) await leaving;
    activate(serverId);
    return serverId;
  }

  @override
  Future<void> connectServer(String serverId, {bool makeActive = false}) async {
    calls.add('connect $serverId');
    await onActivate?.call(serverId);
    if (makeActive) {
      final leaving = _leave(serverId);
      if (leaving != null) await leaving;
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
