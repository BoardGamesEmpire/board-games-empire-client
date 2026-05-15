import 'dart:async';

import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';

import 'dependency_container_impl.dart';

/// Concrete [ServerContext] implementation.
///
/// Manages the [ServerContextState] machine for a single BGE server.
/// Resource lifecycle (WS connections, per-server DB) is stubbed for now
/// and will be filled in during Phase 3 (network) and Phase 2 (storage).
///
/// State transitions are serialized through [_transitionLock] to prevent
/// concurrent mutations. The [ServerOrchestrator] is the only intended
/// caller of lifecycle methods — external code should only observe state
/// via [watchState] and resolve services via [container].
class ServerContextImpl implements ServerContext {
  ServerContextImpl({
    required ServerConfig config,
    DependencyContainer? container,
  }) : serverId = config.id,
       _config = config,
       _container = container ?? DependencyContainerImpl(),
       _state = ServerContextState.initializing,
       _stateController = StreamController<ServerContextState>.broadcast(
         sync: true,
       );

  @override
  final String serverId;

  // Used in activate() (Phase 2: DB open) and suspend() (Phase 3: WS close).
  final ServerConfig _config;

  @override
  DependencyContainer get container => _container;
  final DependencyContainer _container;

  @override
  ServerContextState get state => _state;
  ServerContextState _state;

  final StreamController<ServerContextState> _stateController;

  /// Prevents concurrent state transitions.
  bool _transitioning = false;

  @override
  Future<void> activate() async {
    _assertNotDisposed();

    final allowed = {
      ServerContextState.initializing,
      ServerContextState.backgrounding,
      ServerContextState.monitoring,
    };
    if (!allowed.contains(_state)) {
      throw StateError(
        'Cannot activate context for $serverId from state $_state.',
      );
    }

    await _transition(() async {
      // TODO(phase2): Open per-server Drift DB.
      // TODO(phase3): Open WebSocket connection.
      _setState(ServerContextState.active);
    });
  }

  @override
  Future<void> background() async {
    _assertNotDisposed();

    if (_state != ServerContextState.active) {
      throw StateError(
        'Cannot background context for $serverId from state $_state. '
        'Must be active.',
      );
    }

    await _transition(() async {
      // Resources remain open during backgrounding — no-op here.
      // The orchestrator owns the backgrounding timer.
      _setState(ServerContextState.backgrounding);
    });
  }

  @override
  Future<void> suspend() async {
    _assertNotDisposed();

    if (_state != ServerContextState.backgrounding) {
      throw StateError(
        'Cannot suspend context for $serverId from state $_state. '
        'Must be backgrounding.',
      );
    }

    await _transition(() async {
      // TODO(phase2): Close per-server Drift DB.
      // TODO(phase3): Close WebSocket connection.
      _setState(ServerContextState.monitoring);
    });
  }

  @override
  Future<void> dispose() async {
    if (_state == ServerContextState.disposed) return;

    _setState(ServerContextState.disposed);
    await _container.dispose();
    await _stateController.close();
    // Drain remaining microtasks so any buffered stream events are delivered
    // to subscribers before dispose() returns.
    await Future<void>(() {});
  }

  @override
  Stream<ServerContextState> watchState() {
    // Stream.multi runs the callback synchronously on each listen(),
    // guaranteeing the initial state is emitted before any mutations.
    return Stream.multi((controller) {
      controller.add(_state);
      final sub = _stateController.stream.listen(
        controller.add,
        onError: controller.addError,
        onDone: controller.close,
      );
      controller.onCancel = sub.cancel;
    });
  }

  /// Executes [body] with the transitioning guard held.
  Future<void> _transition(Future<void> Function() body) async {
    if (_transitioning) {
      throw StateError(
        'Concurrent state transition attempted on context for $serverId.',
      );
    }

    _transitioning = true;
    final previousState = _state;
    _setState(ServerContextState.transitioning);

    try {
      await body();
    } catch (e) {
      // Roll back to state before transition attempt.
      _setState(previousState);
      rethrow;
    } finally {
      _transitioning = false;
    }
  }

  void _setState(ServerContextState next) {
    _state = next;
    if (!_stateController.isClosed) {
      _stateController.add(next);
    }
  }

  void _assertNotDisposed() {
    if (_state == ServerContextState.disposed) {
      throw StateError('Context for server $serverId has been disposed.');
    }
  }

  @override
  String toString() => 'ServerContextImpl(serverId: $serverId, state: $_state)';
}

/// Factory function type for creating [ServerContext] instances.
///
/// Injected into [ServerOrchestratorImpl] to allow test substitution
/// without exposing [ServerContextImpl] directly.
typedef ServerContextFactory = ServerContext Function(ServerConfig config);

/// Default production factory. Creates a [ServerContextImpl] with a fresh
/// [DependencyContainerImpl] for each server config.
ServerContext defaultServerContextFactory(ServerConfig config) =>
    ServerContextImpl(config: config);
