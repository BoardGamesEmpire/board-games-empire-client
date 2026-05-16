import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'server_context_impl.dart';

/// Concrete [ServerOrchestrator] implementation.
///
/// Single authority over [ServerContext] creation, destruction, and state
/// transitions. Enforces capacity from [DevicePreferences] and manages
/// backgrounding timers per server.
///
/// Thread-safety: all public methods serialize through [_operationLock] to
/// prevent race conditions during concurrent server switches or connects.
///
/// ## Broadcast controllers — async delivery
///
/// [_activeContextController] and [_contextsController] use the default
/// async delivery (no `sync: true`). Listener callbacks fire in a
/// microtask after `add()`, not synchronously inside the orchestrator
/// method that emitted the event.
///
/// This matters for re-entrancy: a listener that calls back into the
/// orchestrator (e.g. a Bloc that observes `watchActiveContext` and
/// reacts by calling `switchActiveServer`) would otherwise execute
/// inside the original method's lock-held window, tripping the
/// `_operationInProgress` guard with a confusing
/// "Concurrent orchestrator operation attempted" error. With async
/// delivery the listener runs after the originating method returns
/// and the lock has been released.
class ServerOrchestratorImpl implements ServerOrchestrator {
  ServerOrchestratorImpl({
    required ServerRepository serverRepository,
    required DevicePreferencesRepository preferencesRepository,
    ServerContextFactory? contextFactory,
    @visibleForTesting bool? isDesktopOverride,
  }) : _serverRepository = serverRepository,
       _preferencesRepository = preferencesRepository,
       _contextFactory = contextFactory ?? defaultServerContextFactory,
       _isDesktop = isDesktopOverride ?? _detectDesktop();

  final ServerRepository _serverRepository;
  final DevicePreferencesRepository _preferencesRepository;
  final ServerContextFactory _contextFactory;
  final bool _isDesktop;

  final Map<String, ServerContext> _contexts = {};
  final Map<String, Timer> _backgroundingTimers = {};

  final StreamController<ServerContext?> _activeContextController =
      StreamController<ServerContext?>.broadcast();
  final StreamController<Map<String, ServerContext>> _contextsController =
      StreamController<Map<String, ServerContext>>.broadcast();

  String? _activeServerId;
  bool _isInitialized = false;
  bool _disposed = false;

  /// Serializes all mutating operations to prevent concurrent transitions.
  bool _operationInProgress = false;

  @override
  int get maxMonitoringCapacity => _cachedPreferences?.maxMonitoredServers ?? 5;

  @override
  int get currentConnectedCount => _contexts.length;

  @override
  String? get activeServerId => _activeServerId;

  @override
  bool get isInitialized => _isInitialized;

  DevicePreferences? _cachedPreferences;

  @override
  Future<void> initialize() async {
    _assertNotDisposed();
    if (_isInitialized) {
      throw StateError('ServerOrchestrator is already initialized.');
    }

    await _withLock(() async {
      _cachedPreferences = await _preferencesRepository.get();

      // Restore contexts for servers that were connected at last shutdown.
      final connected = await _serverRepository.getConnectedServers();

      // Determine which was last active; fall back to first in list.
      final previouslyActive = connected
          .where((s) => s.isActive)
          .map((s) => s.id)
          .firstOrNull;

      for (final config in connected) {
        final context = _contextFactory(config);
        _contexts[config.id] = context;

        // All restored contexts start in monitoring (resources were released
        // at last shutdown), then the previously-active one is promoted.
        await context.activate(); // initializing → active (then demote below)
        if (config.id != previouslyActive) {
          await context.background(); // active → backgrounding
          await context.suspend(); // backgrounding → monitoring
        }
      }

      _activeServerId = previouslyActive ?? connected.firstOrNull?.id;
      _isInitialized = true;

      _emitContextsChange();
      _emitActiveChange();
    });
  }

  @override
  Future<void> connectServer(String serverId, {bool makeActive = false}) async {
    _assertReady();

    await _withLock(() async {
      final config = await _serverRepository.getServer(serverId);
      if (config == null) throw ServerNotFoundException(serverId);
      if (_contexts.containsKey(serverId)) {
        throw StateError('Server $serverId is already connected.');
      }

      // Enforce capacity.
      final prefs = await _preferencesRepository.get();
      _cachedPreferences = prefs;
      if (_contexts.length >= prefs.maxMonitoredServers) {
        throw ServerCapacityExceededException(
          currentConnected: _contexts.length,
          maxCapacity: prefs.maxMonitoredServers,
        );
      }

      final context = _contextFactory(config);
      _contexts[serverId] = context;

      final shouldBeActive = makeActive || _activeServerId == null;

      if (shouldBeActive) {
        await _activateContext(serverId, context);
      } else {
        // Connect directly into monitoring (no backgrounding timer needed —
        // it was never active in this session).
        await context.activate(); // initializing → active
        await context.background(); // active → backgrounding
        await context.suspend(); // backgrounding → monitoring
        await _serverRepository.updateConnectionState(
          serverId: serverId,
          newState: ConnectionState.monitoring,
        );
      }

      _emitContextsChange();
    });
  }

  @override
  Future<void> disconnectServer(String serverId) async {
    _assertReady();

    await _withLock(() async {
      final config = await _serverRepository.getServer(serverId);
      if (config == null) throw ServerNotFoundException(serverId);

      final context = _contexts[serverId];
      if (context == null) {
        throw StateError('Server $serverId is not connected.');
      }

      _cancelBackgroundingTimer(serverId);

      // If disconnecting the active server, promote another.
      if (_activeServerId == serverId) {
        final nextId = _contexts.keys.where((id) => id != serverId).firstOrNull;

        _activeServerId = nextId;

        if (nextId != null) {
          final nextContext = _contexts[nextId]!;
          _cancelBackgroundingTimer(nextId);
          await _activateContext(nextId, nextContext);
        }

        _emitActiveChange();
      }

      await context.dispose();
      _contexts.remove(serverId);

      await _serverRepository.updateConnectionState(
        serverId: serverId,
        newState: ConnectionState.disconnected,
      );

      _emitContextsChange();
    });
  }

  @override
  Future<void> switchActiveServer(String targetServerId) async {
    _assertReady();

    await _withLock(() async {
      if (targetServerId == _activeServerId) return;

      final targetContext = _contexts[targetServerId];
      if (targetContext == null) {
        throw StateError(
          'Cannot switch to server $targetServerId: not connected.',
        );
      }

      // Background the current active server and start its timer.
      final previousId = _activeServerId;
      if (previousId != null) {
        final previous = _contexts[previousId];
        if (previous != null && previous.state == ServerContextState.active) {
          await previous.background();
          await _serverRepository.updateConnectionState(
            serverId: previousId,
            newState: ConnectionState.backgrounding,
          );
          _startBackgroundingTimer(previousId);
        }
      }

      // Activate the target, cancelling its timer if it was backgrounding.
      _cancelBackgroundingTimer(targetServerId);
      await _activateContext(targetServerId, targetContext);

      _emitContextsChange();
    });
  }

  @override
  ServerContext? getContext(String serverId) => _contexts[serverId];

  @override
  ServerContext? getActiveContext() =>
      _activeServerId != null ? _contexts[_activeServerId] : null;

  @override
  Stream<ServerContext?> watchActiveContext() =>
      _activeContextController.stream;

  @override
  Stream<Map<String, ServerContext>> watchContexts() =>
      _contextsController.stream;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    for (final timer in _backgroundingTimers.values) {
      timer.cancel();
    }
    _backgroundingTimers.clear();

    for (final context in _contexts.values) {
      await context.dispose();
    }
    _contexts.clear();

    await _activeContextController.close();
    await _contextsController.close();

    _isInitialized = false;
  }

  /// Brings [context] to [ServerContextState.active] from any connected state.
  Future<void> _activateContext(String serverId, ServerContext context) async {
    final activateableStates = {
      ServerContextState.initializing,
      ServerContextState.backgrounding,
      ServerContextState.monitoring,
    };

    if (activateableStates.contains(context.state)) {
      await context.activate();
    }
    // already active — no-op

    _activeServerId = serverId;

    await _serverRepository.updateConnectionState(
      serverId: serverId,
      newState: ConnectionState.active,
    );
    await _serverRepository.updateLastActive(serverId, DateTime.now().toUtc());

    _emitActiveChange();
  }

  void _startBackgroundingTimer(String serverId) {
    _cancelBackgroundingTimer(serverId);

    final prefs = _cachedPreferences;
    final configOverride = null; // TODO: read per-server override from repo
    final timeoutSeconds =
        configOverride ??
        (prefs?.backgroundingTimeoutSeconds(isDesktop: _isDesktop) ??
            (_isDesktop ? 900 : 300));

    _backgroundingTimers[serverId] = Timer(
      Duration(seconds: timeoutSeconds),
      () => _onBackgroundingTimerExpired(serverId),
    );
  }

  void _cancelBackgroundingTimer(String serverId) {
    _backgroundingTimers.remove(serverId)?.cancel();
  }

  void _onBackgroundingTimerExpired(String serverId) {
    _backgroundingTimers.remove(serverId);

    final context = _contexts[serverId];
    if (context == null || context.state != ServerContextState.backgrounding) {
      return;
    }

    // Fire-and-forget — errors are logged, not propagated.
    Future(() async {
      try {
        await context.suspend();
        await _serverRepository.updateConnectionState(
          serverId: serverId,
          newState: ConnectionState.monitoring,
        );
        _emitContextsChange();
      } catch (e, st) {
        // TODO: wire in a proper error reporting channel
        debugPrint(
          '[ServerOrchestrator] Error suspending $serverId on timer: $e\n$st',
        );
      }
    });
  }

  Future<void> _withLock(Future<void> Function() body) async {
    if (_operationInProgress) {
      throw StateError(
        'Concurrent orchestrator operation attempted. '
        'Await the previous operation before starting another.',
      );
    }
    _operationInProgress = true;
    try {
      await body();
    } finally {
      _operationInProgress = false;
    }
  }

  @override
  bool canConnect() {
    if (_disposed) {
      return false;
    }

    return currentConnectedCount < maxMonitoringCapacity;
  }

  void _emitActiveChange() {
    if (!_activeContextController.isClosed) {
      _activeContextController.add(getActiveContext());
    }
  }

  void _emitContextsChange() {
    if (!_contextsController.isClosed) {
      _contextsController.add(Map.unmodifiable(_contexts));
    }
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError('ServerOrchestrator has been disposed.');
    }
  }

  void _assertReady() {
    _assertNotDisposed();
    if (!_isInitialized) {
      throw StateError(
        'ServerOrchestrator is not initialized. Call initialize() first.',
      );
    }
  }

  static bool _detectDesktop() {
    try {
      return Platform.isMacOS || Platform.isLinux || Platform.isWindows;
    } catch (_) {
      return false;
    }
  }
}
