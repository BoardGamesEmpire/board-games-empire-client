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
/// Thread-safety: all public methods serialize through [_withLock] to
/// prevent race conditions during concurrent server switches or connects.
///
/// ## Activation can fail
///
/// `ServerContext.activate()` performs real work (opens the encrypted
/// per-server database, builds the network stack) and can throw. Every
/// orchestrator path therefore follows the same discipline: **attempt the
/// activation first, commit orchestrator state (`_activeServerId`,
/// `_contexts`, repository connection states, stream emissions) only after
/// it succeeds.** A failed activation leaves that server unavailable but
/// the orchestrator consistent and the app running.
///
/// ## Broadcast controllers — async delivery
///
/// [_activeContextController] and [_contextsController] use the default
/// async delivery. Listener callbacks fire in a microtask after `add()`,
/// not inside the orchestrator method that emitted the event.
///
/// This matters for re-entrancy: a listener that calls back into the
/// orchestrator (e.g. a Bloc that observes `watchActiveContext` and
/// reacts by calling `switchActiveServer`) would otherwise execute
/// inside the original method's lock-held window, tripping the
/// `_operationInProgress` guard with a confusing
/// "Concurrent orchestrator operation attempted" error. With async
/// delivery the listener runs after the originating method returns
/// and the lock has been released.
///
/// ## Config bookkeeping (#37)
///
/// [_configs] mirrors [_contexts] key-for-key: every path that registers
/// a context registers its [ServerConfig], and every path that removes a
/// context removes its config. [activeConfig] reads through
/// [_activeServerId], so it commits together with the active pointer and
/// the active-context emission — by the time a listener is delivered an
/// event (async delivery, above), the config it reads is consistent with
/// that event. The stored config is a connect-time snapshot; that is
/// sufficient while no rename-server flow exists.
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

  /// Connect-time [ServerConfig] snapshots, keyed like [_contexts] and
  /// mutated in lockstep with it (see class docs, "Config bookkeeping").
  final Map<String, ServerConfig> _configs = {};

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

  /// The currently running locked operation — awaited by [dispose] so
  /// teardown never interleaves with an in-flight connect/switch.
  Future<void>? _inFlightOperation;

  @override
  int get maxMonitoringCapacity => _cachedPreferences?.maxMonitoredServers ?? 5;

  @override
  int get currentConnectedCount => _contexts.length;

  @override
  String? get activeServerId => _activeServerId;

  @override
  ServerConfig? get activeConfig {
    final id = _activeServerId;
    return id == null ? null : _configs[id];
  }

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

      // One bad server (key recovery failed twice, unreachable resources,
      // …) must not prevent the orchestrator from initializing: restore
      // each context into monitoring independently, drop the ones that
      // fail. A dropped context has its persisted connection state cleared
      // so it isn't retried on every startup.
      for (final config in connected) {
        final context = _contextFactory(config);
        try {
          await context.activate(); // initializing → active
          await context.background(); // active → backgrounding
          await context.suspend(); // backgrounding → monitoring
          _contexts[config.id] = context;
          _configs[config.id] = config;
        } catch (e, st) {
          _logError('restore of server ${config.id} failed', e, st);
          await _disposeQuietly(context);
          await _updateStateQuietly(config.id, ConnectionState.disconnected);
        }
      }

      // Choose the active server, then actually promote it to `active` so
      // `_activeServerId` never points at a merely-monitoring context.
      final chosenActive =
          (previouslyActive != null && _contexts.containsKey(previouslyActive))
          ? previouslyActive
          : _contexts.keys.firstOrNull;

      if (chosenActive != null) {
        try {
          await _ensureActive(_contexts[chosenActive]!);
          await _commitActive(chosenActive);
        } catch (e, st) {
          // Promotion of the chosen active failed: drop it and leave the
          // orchestrator with no active server rather than a non-active
          // pointer. Remaining monitoring contexts stay connected.
          _logError('activating restored server $chosenActive failed', e, st);
          await _disposeQuietly(_contexts.remove(chosenActive)!);
          _configs.remove(chosenActive);
          await _updateStateQuietly(chosenActive, ConnectionState.disconnected);
          _activeServerId = null;
        }
      } else {
        _activeServerId = null;
      }

      _isInitialized = true;

      _emitContextsChange();
      _emitActiveChange();
    });
  }

  @override
  Future<String> addAndActivateServer({
    required String displayName,
    required String serverUrl,
    required String bgeServerId,
    required ServerIdentity identity,
  }) async {
    _assertReady();

    // Persist first. The repository enforces uniqueness
    // (DuplicateServerException) atomically on its own; orchestrator
    // state is untouched until connectServer below, which serializes
    // through the standard lock. connectServer cannot be invoked inside
    // _withLock (the re-entrancy guard would trip), so this composes the
    // two steps instead — the window between them is harmless: the row
    // exists in ConnectionState.disconnected, exactly like any other
    // registered-but-unconnected server.
    final config = await _serverRepository.addServer(
      displayName: displayName,
      serverUrl: serverUrl,
      bgeServerId: bgeServerId,
      identity: identity,
    );

    // Connect through the standard path: capacity enforcement, demotion
    // of any current active server, and the activate-before-commit
    // discipline all apply unchanged. On any failure the just-persisted
    // row is removed again so a failed onboarding never leaves a zombie
    // config behind (#36).
    try {
      await connectServer(config.id, makeActive: true);
    } catch (_) {
      try {
        await _serverRepository.removeServer(config.id);
      } catch (e, st) {
        // Rollback is best-effort: the original failure is the one the
        // caller needs to see.
        _logError(
          'rollback of ${config.id} after failed onboarding activation',
          e,
          st,
        );
      }
      rethrow;
    }

    return config.id;
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
      final shouldBeActive = makeActive || _activeServerId == null;

      // Bring the context to its target state BEFORE registering it — a
      // failed activation must not leave an orphaned entry in [_contexts]
      // that permanently blocks reconnection.
      try {
        if (shouldBeActive) {
          await _ensureActive(context);
        } else {
          // Connect directly into monitoring (no backgrounding timer needed
          // — it was never active in this session).
          await context.activate(); // initializing → active
          await context.background(); // active → backgrounding
          await context.suspend(); // backgrounding → monitoring
        }
      } catch (_) {
        await _disposeQuietly(context);
        rethrow;
      }

      _contexts[serverId] = context;
      _configs[serverId] = config;

      if (shouldBeActive) {
        // Demote the current active server (if a different one) before
        // committing the newcomer, so the single-active invariant holds.
        final previousId = _activeServerId;
        if (previousId != null && previousId != serverId) {
          final previous = _contexts[previousId];
          if (previous != null && previous.state == ServerContextState.active) {
            try {
              await previous.background();
              await _serverRepository.updateConnectionState(
                serverId: previousId,
                newState: ConnectionState.backgrounding,
              );
              _startBackgroundingTimer(previousId);
            } catch (e, st) {
              // Undo the newcomer's activation and drop it — the switch
              // half-failed and must not leave two active contexts.
              _logError('demoting $previousId on connect failed', e, st);
              // Restore `previous` to active if it was already backgrounded,
              // so _activeServerId keeps pointing at a genuinely active
              // context.
              _cancelBackgroundingTimer(previousId);
              if (previous.state == ServerContextState.backgrounding) {
                try {
                  await previous.activate();
                } catch (e2, st2) {
                  _logError('restoring previous $previousId failed', e2, st2);
                }
              }
              await _disposeQuietly(_contexts.remove(serverId)!);
              _configs.remove(serverId);
              rethrow;
            }
          }
        }
        await _commitActive(serverId);
      } else {
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

      // If disconnecting the active server, promote another — committing
      // the new active id only if its activation succeeds. On failure the
      // app continues with no active server rather than pointing at a
      // context that is not actually active.
      if (_activeServerId == serverId) {
        final nextId = _contexts.keys.where((id) => id != serverId).firstOrNull;

        String? promotedId;
        if (nextId != null) {
          final nextContext = _contexts[nextId]!;
          final nextWasBackgrounding =
              nextContext.state == ServerContextState.backgrounding;
          _cancelBackgroundingTimer(nextId);
          try {
            await _ensureActive(nextContext);
            promotedId = nextId;
          } catch (e, st) {
            _logError('promotion of server $nextId failed', e, st);
            // Restore the timer we cancelled so a still-backgrounding
            // context isn't stranded (never suspends → leaks resources).
            if (nextWasBackgrounding &&
                nextContext.state == ServerContextState.backgrounding) {
              _startBackgroundingTimer(nextId);
            }
          }
        }

        if (promotedId != null) {
          await _commitActive(promotedId);
        } else {
          _activeServerId = null;
          _emitActiveChange();
        }
      }

      await context.dispose();
      _contexts.remove(serverId);
      _configs.remove(serverId);

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

      // Activate the target FIRST. If it fails, nothing has been mutated:
      // the previous server is still active and still the active id. (The
      // brief window where both contexts are `active` is the documented
      // co-active window.)
      final wasBackgrounding =
          targetContext.state == ServerContextState.backgrounding;
      _cancelBackgroundingTimer(targetServerId);
      try {
        await _ensureActive(targetContext);
      } catch (_) {
        // Restore the timer the failed target lost, if it was counting
        // down toward suspension.
        if (wasBackgrounding &&
            targetContext.state == ServerContextState.backgrounding) {
          _startBackgroundingTimer(targetServerId);
        }
        rethrow;
      }

      // Demote the previous active server and start its timer. If demotion
      // fails, we must NOT commit the target — that would leave two active
      // contexts. Roll the target back to backgrounding and rethrow so the
      // switch fails atomically with the previous server still active.
      final previousId = _activeServerId;
      if (previousId != null) {
        final previous = _contexts[previousId];
        if (previous != null && previous.state == ServerContextState.active) {
          try {
            await previous.background();
            await _serverRepository.updateConnectionState(
              serverId: previousId,
              newState: ConnectionState.backgrounding,
            );
            _startBackgroundingTimer(previousId);
          } catch (e, st) {
            _logError('backgrounding of server $previousId failed', e, st);
            // Restore `previous` to active if we already backgrounded it —
            // it must remain the sole active server per the invariant.
            _cancelBackgroundingTimer(previousId);
            if (previous.state == ServerContextState.backgrounding) {
              try {
                await previous.activate();
              } catch (e3, st3) {
                _logError('restoring previous $previousId failed', e3, st3);
              }
            }
            // Undo the target activation to preserve the single-active
            // invariant, restoring its *pre-switch* state rather than
            // over-suspending: a target that was backgrounding goes back to
            // backgrounding (timer restored); one that was monitoring is
            // fully suspended.
            try {
              if (targetContext.state == ServerContextState.active) {
                await targetContext.background();
                if (wasBackgrounding) {
                  _startBackgroundingTimer(targetServerId);
                } else {
                  await targetContext.suspend();
                }
              }
            } catch (e2, st2) {
              _logError('rolling back target $targetServerId failed', e2, st2);
            }
            rethrow;
          }
        }
      }

      await _commitActive(targetServerId);
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

    // Let an in-flight operation settle before tearing its contexts down.
    final inFlight = _inFlightOperation;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {
        // The operation's own caller receives this error.
      }
    }

    for (final timer in _backgroundingTimers.values) {
      timer.cancel();
    }
    _backgroundingTimers.clear();

    for (final context in _contexts.values) {
      await context.dispose();
    }
    _contexts.clear();
    _configs.clear();

    await _activeContextController.close();
    await _contextsController.close();

    _isInitialized = false;
  }

  /// Brings [context] to [ServerContextState.active] from any connected
  /// state. Performs the transition only — orchestrator state is committed
  /// separately via [_commitActive] once the caller decides the activation
  /// counts.
  Future<void> _ensureActive(ServerContext context) async {
    final activateableStates = {
      ServerContextState.initializing,
      ServerContextState.backgrounding,
      ServerContextState.monitoring,
    };

    if (activateableStates.contains(context.state)) {
      await context.activate();
    }
    // already active — no-op
  }

  /// Commits [serverId] as the active server: repository connection state,
  /// orchestrator pointer, and the active-context emission. Only called
  /// after the context's activation has succeeded.
  ///
  /// The persisted-state writes are best-effort: a repository failure is
  /// logged, not thrown. If they threw, callers would be left with the
  /// context already activated (and the previous one already demoted) but
  /// the switch only half-applied — the single-active invariant would be
  /// violated with no clean rollback. Since persisted connection state is a
  /// cache the orchestrator reconciles on the next `initialize`, the
  /// in-memory pointer + emission are the authority and must always commit.
  Future<void> _commitActive(String serverId) async {
    await _updateStateQuietly(serverId, ConnectionState.active);
    try {
      await _serverRepository.updateLastActive(
        serverId,
        DateTime.now().toUtc(),
      );
    } catch (e, st) {
      _logError('persisting lastActive for $serverId failed', e, st);
    }

    _activeServerId = serverId;
    _emitActiveChange();
  }

  Future<void> _disposeQuietly(ServerContext context) async {
    try {
      await context.dispose();
    } catch (e, st) {
      _logError('disposal of context ${context.serverId} failed', e, st);
    }
  }

  /// Best-effort persisted-state update used on failure paths, where a
  /// secondary repository error must not mask the primary failure.
  Future<void> _updateStateQuietly(
    String serverId,
    ConnectionState state,
  ) async {
    try {
      await _serverRepository.updateConnectionState(
        serverId: serverId,
        newState: state,
      );
    } catch (e, st) {
      _logError('persisting $state for $serverId failed', e, st);
    }
  }

  void _logError(String what, Object error, StackTrace stackTrace) {
    // TODO: wire in a proper error reporting channel
    debugPrint('[ServerOrchestrator] $what: $error\n$stackTrace');
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
        _logError('suspending $serverId on timer failed', e, st);
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
    final future = Future.sync(body);
    _inFlightOperation = future;
    try {
      await future;
    } finally {
      _operationInProgress = false;
      _inFlightOperation = null;
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
