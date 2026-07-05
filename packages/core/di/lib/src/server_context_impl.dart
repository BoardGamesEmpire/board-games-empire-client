import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';

import 'dependency_container_impl.dart';

/// Concrete [ServerContext] implementation.
///
/// Manages the [ServerContextState] machine for a single BGE server and owns
/// the per-server resource lifecycle. Concrete resources (per-server DB,
/// HTTP client, repositories) are wired by the injected
/// [ServerScopeInstaller]s — the seam that keeps this package free of
/// storage/network dependencies. The platform app composes the installer
/// list (`StorageScopeInstaller` from `drift_storage`,
/// `NetworkScopeInstaller` from `dio_network`, …).
///
/// ## Scope lifecycle
///
/// - `activate()` from `initializing` or `monitoring` runs every installer,
///   in order, against a fresh scope. Installers acquire real resources
///   (open the encrypted DB, build the Dio) so failures surface here —
///   on failure the scope is reset and [_transition] rolls the state back;
///   the server stays unavailable but the app keeps running, and a later
///   `activate()` retries from a clean container.
/// - `activate()` from `backgrounding` re-runs **nothing**: backgrounding
///   retains open resources by design.
/// - `suspend()` disposes the current scope — every `dispose:` callback
///   supplied at registration runs (DB close, Dio close, repository
///   teardown) — and swaps in a fresh, empty container for the next
///   activation. Per-server resources only; the app-global meta database is
///   owned by the app bootstrap and is never touched here.
/// - `dispose()` tears the scope down for good.
///
/// ## Stable container identity
///
/// [container] returns the same [DependencyContainer] object for the
/// context's entire life — the documented "exactly one container per
/// context" contract — while suspend/re-activate cycles swap the *inner*
/// GetIt-backed container behind a delegating facade
/// ([_SwappableContainer]). Holders of `context.container` never see a
/// disposed object; between suspend and the next activate, `get<T>()`
/// reports not-registered (fresh scope) rather than throwing
/// disposed-container errors.
///
/// State transitions are serialized through [_transitioning] to prevent
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
    List<ServerScopeInstaller> installers = const [],
    DependencyContainer Function()? containerFactory,
  }) : serverId = config.id,
       _config = config,
       _installers = installers,
       _container = _SwappableContainer(
         containerFactory ?? DependencyContainerImpl.new,
       ),
       _state = ServerContextState.initializing,
       _stateController = StreamController<ServerContextState>.broadcast();

  @override
  final String serverId;

  final ServerConfig _config;

  final List<ServerScopeInstaller> _installers;

  @override
  DependencyContainer get container => _container;
  final _SwappableContainer _container;

  @override
  ServerContextState get state => _state;
  ServerContextState _state;

  final StreamController<ServerContextState> _stateController;

  /// Prevents concurrent state transitions.
  bool _transitioning = false;

  /// The currently running transition, if any — awaited by [dispose] so
  /// teardown never interleaves with an installer mid-flight.
  Future<void>? _inFlightTransition;

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

    // Backgrounding retained the open resources — only a cold start
    // (initializing) or a suspended context (monitoring, scope torn down)
    // installs. Captured before _transition sets state to `transitioning`.
    final needsInstall = _state != ServerContextState.backgrounding;

    await _transition(() async {
      if (needsInstall) {
        try {
          for (final installer in _installers) {
            await installer.install(_container, _config);
          }
        } catch (_) {
          // Discard partial registrations so a retry starts from a clean
          // scope; _transition's catch rolls the state back and rethrows.
          // The reset is guarded so a throwing dispose callback (GetIt does
          // not shield them) cannot mask the real installer error.
          try {
            await _container.replaceInner();
          } catch (teardownError) {
            assert(() {
              debugPrint(
                'ServerContext($serverId): scope reset after a failed '
                'activation threw (suppressed in favor of the original '
                'installer error): $teardownError',
              );
              return true;
            }());
          }
          rethrow;
        }
      }
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
      // Dispose the scope: every dispose callback registered by the
      // installers runs here (per-server DB close, Dio close, repository
      // teardown), then a fresh container takes its place for the next
      // activation. The app-global meta database is not a per-server
      // resource and is untouched.
      //
      // A throwing dispose callback must not abort the transition: that
      // would roll back to `backgrounding`, and on the orchestrator's
      // timer-driven suspend path (where the error is only logged) the
      // context would be stranded in backgrounding with its timer already
      // fired — never suspending, leaking resources. Log and proceed to
      // monitoring, matching dispose()'s guarded teardown. replaceInner
      // still installs a fresh inner container even when the old one's
      // disposal throws.
      try {
        await _container.replaceInner();
      } catch (e) {
        assert(() {
          debugPrint(
            'ServerContext($serverId): scope disposal threw during '
            'suspend(): $e',
          );
          return true;
        }());
      }
      _setState(ServerContextState.monitoring);
    });
  }

  @override
  Future<void> dispose() async {
    if (_state == ServerContextState.disposed) return;

    // Let any in-flight transition settle before tearing down — activate()
    // now performs real async work (DB open, client construction), and
    // disposing the container mid-install would rip resources out from
    // under it. A failed transition is fine to proceed past.
    final inFlight = _inFlightTransition;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {
        // The transition's own caller receives this error; disposal
        // continues regardless.
      }
    }
    if (_state == ServerContextState.disposed) return;

    _setState(ServerContextState.disposed);
    try {
      await _container.dispose();
    } catch (e) {
      // A service's dispose callback threw. Log and continue — the state
      // stream must still close so disposal is reliably idempotent and the
      // orchestrator's teardown isn't left brittle.
      assert(() {
        debugPrint(
          'ServerContext($serverId): container disposal threw during '
          'dispose(): $e',
        );
        return true;
      }());
    }
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
    final future = _runTransition(body);
    _inFlightTransition = future;
    try {
      await future;
    } finally {
      _transitioning = false;
      _inFlightTransition = null;
    }
  }

  Future<void> _runTransition(Future<void> Function() body) async {
    final previousState = _state;
    _setState(ServerContextState.transitioning);

    try {
      await body();
    } catch (e) {
      // Roll back to the state before the transition attempt — unless the
      // context was disposed meanwhile, which must never be overwritten
      // with a live state.
      if (_state != ServerContextState.disposed) {
        _setState(previousState);
      }
      rethrow;
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

/// Stable-identity [DependencyContainer] facade over a swappable inner
/// container.
///
/// The facade object *is* the container the context exposes for its whole
/// life; suspend/re-activate cycles replace only the inner GetIt-backed
/// instance via [replaceInner]. This preserves the "exactly one container
/// per context" contract for external holders while still giving each
/// activation a clean scope.
class _SwappableContainer implements DependencyContainer {
  _SwappableContainer(this._factory) : _inner = null;

  final DependencyContainer Function() _factory;

  /// Lazily created so the first activation and every post-suspend
  /// activation follow the identical code path.
  DependencyContainer? _inner;

  bool _disposed = false;

  DependencyContainer get _current {
    if (_disposed) {
      throw StateError(
        'DependencyContainer has been disposed and cannot be used.',
      );
    }
    return _inner ??= _factory();
  }

  /// Disposes the current inner container (running every registration's
  /// dispose callback) and prepares a fresh one for subsequent use.
  Future<void> replaceInner() async {
    final old = _inner;
    _inner = null;
    if (old != null) await old.dispose();
  }

  @override
  T get<T extends Object>() => _current.get<T>();

  @override
  void registerSingleton<T extends Object>(
    T instance, {
    FutureOr<void> Function(T instance)? dispose,
  }) => _current.registerSingleton<T>(instance, dispose: dispose);

  @override
  void registerLazySingleton<T extends Object>(
    T Function() factory, {
    FutureOr<void> Function(T instance)? dispose,
  }) => _current.registerLazySingleton<T>(factory, dispose: dispose);

  @override
  void registerFactory<T extends Object>(T Function() factory) =>
      _current.registerFactory<T>(factory);

  @override
  bool isRegistered<T extends Object>() => _current.isRegistered<T>();

  @override
  Future<void> dispose() async {
    // Terminal and idempotent. If no inner container was ever created there
    // is nothing to dispose — and none is constructed just to be torn down.
    if (_disposed) return;
    _disposed = true;
    final old = _inner;
    _inner = null;
    if (old != null) await old.dispose();
  }
}

/// Factory function type for creating [ServerContext] instances.
///
/// Injected into [ServerOrchestratorImpl] to allow test substitution
/// without exposing [ServerContextImpl] directly.
typedef ServerContextFactory = ServerContext Function(ServerConfig config);

/// Default production factory. Creates a [ServerContextImpl] with a fresh
/// [DependencyContainerImpl] for each server config — with **no installers**.
///
/// The platform app composes the real factory (storage + network installers)
/// in its bootstrap (#31); this default remains for tests and for contexts
/// that need no per-server resources.
ServerContext defaultServerContextFactory(ServerConfig config) =>
    ServerContextImpl(config: config);
