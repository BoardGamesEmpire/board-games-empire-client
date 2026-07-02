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
///
/// ## Stream delivery — async controller + Stream.multi wrapper
///
/// [_stateController] uses the default async delivery (no `sync: true`).
/// Listener callbacks fire in a microtask after [_setState] / `add()`,
/// not synchronously inside the transition that triggered them. This
/// preserves the same re-entrancy property the orchestrator's broadcast
/// controllers maintain: a listener that calls back into a lifecycle
/// method (e.g. a Bloc that observes `watchState` and reacts by calling
/// another method on the context) executes after the original
/// transition has fully unwound, not inside the `_transitioning` guard.
///
/// [watchState] still emits the current state on subscribe via the
/// [Stream.multi] wrapper — which delivers the initial value through
/// the multi controller's own `add()` (also async, but cheaply: the
/// first event-loop turn after `listen()`). The Stream.multi approach
/// is preferred to a sync controller because it gives the
/// "current-state-on-subscribe" semantic without forcing every
/// subsequent emission to fire synchronously.
class ServerContextImpl implements ServerContext {
  ServerContextImpl({
    required ServerConfig config,
    DependencyContainer? container,
  }) : serverId = config.id,
       _config = config,
       _container = container ?? DependencyContainerImpl(),
       _state = ServerContextState.initializing,
       _stateController = StreamController<ServerContextState>.broadcast();

  @override
  final String serverId;

  // Used in activate() (Phase 2: DB open) and suspend() (Phase 3: WS close).
  // ignore: unused_field
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
    // Yield one event-loop turn so any buffered stream events queued
    // via [_stateController.add] reach their subscribers before
    // dispose() returns.
    //
    // The original comment said this drained microtasks, which was
    // mechanically wrong: `await Future<void>(() {})` schedules the
    // callback as an event-loop TASK (the back of the event queue),
    // not a microtask. The effect is the same one the comment was
    // grasping at — Dart drains the microtask queue before running
    // the next event-loop task, so awaiting an event-task does
    // implicitly wait for all currently-scheduled microtasks
    // (including the broadcast controller's pending delivery
    // callbacks) to finish. But describing it as "drains microtasks"
    // suggests `scheduleMicrotask` or similar; the correct framing
    // is "yield one event-loop turn, which gives the microtask
    // queue a chance to drain as a side effect."
    await Future<void>(() {});
  }

  @override
  Stream<ServerContextState> watchState() {
    // Stream.multi runs the callback synchronously on each listen(),
    // giving us a hook to push the current state to the new subscriber
    // before we wire up the underlying broadcast forwarding. The initial
    // emission is delivered through the multi controller's own `add()`
    // (async — first microtask after listen), but it's guaranteed to land
    // ahead of any subsequent state change emitted via [_stateController]
    // because [_setState] is called synchronously while [_stateController]
    // delivery is itself async. The combination keeps the
    // "current state on subscribe" semantic without needing a sync
    // controller.
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
