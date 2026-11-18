import 'dart:async';
import 'dart:io' show Platform;

import 'package:di/src/server_context_impl.dart';
import 'package:flutter/foundation.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:observability/observability.dart';

/// Concrete [ServerOrchestrator] implementation.
///
/// Single authority over [ServerContext] creation, destruction, and state
/// transitions. Enforces capacity from [DevicePreferences] and manages
/// backgrounding timers per server.
///
/// ## Lifecycle commands queue (#174)
///
/// [initialize], [connectServer], [disconnectServer], [switchActiveServer]
/// and a backgrounding timer's expiry each run as one command on a single
/// queue ([_command]), in the order they were called. A call made while
/// another command runs waits for it instead of failing. Each command reads
/// the state it transitions when it runs, not when it was called, so an
/// expiry that a switch made stale while it waited is dropped.
///
/// A call made from inside a running command (say, from a context's
/// `activate`) would wait on itself forever, so it fails fast with a
/// [StateError] instead. That includes [dispose], which waits for the
/// queue. Each command runs in a zone carrying a token of its own under
/// [_commandZoneKey], and a call is re-entrant when its zone carries the
/// token of the command running now ([_running]).
///
/// The token is the command's, not the orchestrator's, because a zone
/// outlives the command that ran in it. Whatever a command starts keeps
/// that zone: the sync engines, listeners and timers a context's `activate`
/// installs. A call one of them makes once the command has finished carries
/// a token that is no longer running, so it queues like any other. A call
/// made from such work while its command still runs is refused, whether or
/// not the command waits for it: the two can't be told apart.
///
/// Backgrounding timers are created outside any command's zone, in the
/// nearest enclosing zone that isn't one ([_outsideCommands]). A timer
/// started inside a command would fire in that command's zone, and an
/// expiry that fired while the command was still running would be refused
/// as re-entrant. The root zone would be wrong too: it is outside the app's
/// guarded error zone, and a test's fake clock never fires it.
///
/// [dispose] waits for every command queued before it, then tears down.
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
/// not inside the orchestrator method that emitted the event, and in the
/// zone the listener subscribed from. A listener that calls back into the
/// orchestrator (e.g. a Bloc that observes `watchActiveContext` and reacts
/// by calling `switchActiveServer`) is therefore not a re-entrant call: its
/// command queues behind the one that emitted.
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
///
/// ## Promotion order (#175)
///
/// Disconnecting the active server promotes the **most recently active**
/// of the remaining connected servers, as the [ServerOrchestrator]
/// contract states. [_lastActiveTick] is that record: [_commitActive]
/// stamps the newly active server with a monotonically increasing
/// counter, and [_mostRecentlyActiveOther] promotes the highest.
///
/// The counter is removed with the context, on the same paths that clear
/// [_configs], so recency describes a server's *current* connection. A
/// server that disconnects and reconnects therefore starts with no
/// recency rather than reclaiming a stale stamp — it has not been active
/// since it came back, and promoting it over a server that has been
/// would not be "most recently active" in any sense a user would
/// recognize.
///
/// A server that has never been active carries no tick and ranks below
/// every server that has; among equals the insertion order of
/// [_contexts] decides, which is the pre-#175 behavior preserved as the
/// tiebreak.
class ServerOrchestratorImpl implements ServerOrchestrator {
  ServerOrchestratorImpl({
    required this._serverRepository,
    required this._preferencesRepository,
    ServerContextFactory? contextFactory,
    @visibleForTesting bool? isDesktopOverride,
  }) : _contextFactory = contextFactory ?? defaultServerContextFactory,
       _isDesktop = isDesktopOverride ?? _detectDesktop();

  final ServerRepository _serverRepository;
  final DevicePreferencesRepository _preferencesRepository;
  final ServerContextFactory _contextFactory;
  final bool _isDesktop;
  final BgeLogger _log = BgeLogger('bge.di.server_orchestrator');

  /// The connected contexts, keyed by local server id.
  ///
  /// Iteration order is load-bearing, not incidental: a Dart map literal is
  /// a `LinkedHashMap`, and [_mostRecentlyActiveOther] leans on that
  /// insertion order as the promotion tiebreak among servers with no
  /// recency. Swapping in an unordered or sorted map would change which
  /// server gets promoted — the "falls back to insertion order" test
  /// covers that, so it would fail rather than drift silently.
  final Map<String, ServerContext> _contexts = {};

  /// Connect-time [ServerConfig] snapshots, keyed like [_contexts] and
  /// mutated in lockstep with it (see class docs, "Config bookkeeping").
  final Map<String, ServerConfig> _configs = {};

  /// Activation recency, newest = highest (see class docs, "Promotion
  /// order"). A monotonic counter rather than a timestamp: promotion only
  /// needs the ordering, and a counter cannot be perturbed by clock skew,
  /// NTP steps, or two activations landing in the same clock tick.
  final Map<String, int> _lastActiveTick = {};
  int _activationTick = 0;

  final Map<String, Timer> _backgroundingTimers = {};

  /// Bumped on every start and cancel of a server's backgrounding timer. An
  /// expiry carries the generation its timer started with, and one that
  /// waited in the queue past a cancel or restart finds it stale.
  final Map<String, int> _timerGeneration = {};

  final StreamController<ServerContext?> _activeContextController =
      StreamController<ServerContext?>.broadcast();
  final StreamController<Map<String, ServerContext>> _contextsController =
      StreamController<Map<String, ServerContext>>.broadcast();

  String? _activeServerId;
  bool _isInitialized = false;
  bool _disposed = false;

  /// Completes when the last queued command has; never completes with an
  /// error. The next command chains onto it.
  Future<void> _tail = Future<void>.value();

  /// The zone key a command's token is carried under (see class docs,
  /// "Lifecycle commands queue").
  static final Object _commandZoneKey = Object();

  /// The token of the command running now, or null between commands.
  Object? _running;

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

    await _command(() async {
      // Checked when the command runs, so a second call that queued behind
      // the first fails instead of restoring every context again.
      if (_isInitialized) {
        throw StateError('ServerOrchestrator is already initialized.');
      }

      _cachedPreferences = await _preferencesRepository.get();

      // Restore contexts for servers that were connected at last shutdown.
      final connected = await _serverRepository.getConnectedServers();

      // One bad server (key recovery failed twice, unreachable resources,
      // …) must not prevent the orchestrator from initializing: restore
      // each context into monitoring independently, drop the ones that
      // fail. A dropped context has its persisted connection state cleared
      // so it isn't retried on every startup while another server works.
      //
      // Except when the key store could not be reached: that says nothing
      // about the server, whose key may be intact. Initialization fails
      // instead, which the shell shows as a retryable error, and the
      // persisted state stays for the next attempt (#428). Contexts already
      // restored are released by [dispose].
      for (final config in connected) {
        await _restoreIntoMonitoring(config);
      }

      // Promote a restored server to `active`, so `_activeServerId` never
      // points at a merely-monitoring context: the one that was active,
      // else the most recently active. One that fails to activate is
      // dropped and the next tried, since saved servers with none active
      // fail the boot (#217).
      await _promoteFirst([
        for (final config in _byRecency(connected))
          if (_contexts.containsKey(config.id)) config.id,
      ]);

      // With none active, the disconnected servers are tried too, the most
      // recently active first. A device with one saved server would
      // otherwise never recover from a single failed restore: the server
      // stays disconnected, and every start lands on a screen with no way
      // out (#217). The first that activates ends the search. A boot needs
      // no more than that, so the rest stay disconnected, within capacity
      // and without opening each one's database. Servers that already
      // failed in this call are not tried twice.
      if (_activeServerId == null) {
        final tried = {for (final config in connected) config.id};
        final disconnected = (await _serverRepository.getAllServers()).where(
          (config) => config.isDisconnected && !tried.contains(config.id),
        );
        for (final config in _byRecency(disconnected)) {
          if (await _restoreIntoMonitoring(config) &&
              await _promoteFirst([config.id])) {
            break;
          }
        }
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

    // Persist first. The repository's table constraints keep a server from
    // being added twice, even by two adds at once, and the repository
    // reports either case as DuplicateServerException (#184). Orchestrator
    // state is untouched until connectServer below, which queues like any
    // other command. connectServer cannot be called from inside a command
    // (it would fail as re-entrant), so this composes the two steps
    // instead — the window between them is harmless: the row exists in
    // ConnectionState.disconnected, exactly like any other
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
    } on Object catch (_) {
      try {
        await _serverRepository.removeServer(config.id);
      } on Object catch (e, st) {
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

    await _command(() async {
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
            } on Object catch (e, st) {
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
                } on Object catch (e2, st2) {
                  _logError('restoring previous $previousId failed', e2, st2);
                }
              }
              await _disposeQuietly(_contexts.remove(serverId)!);
              _configs.remove(serverId);
              _lastActiveTick.remove(serverId);
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

    await _command(() async {
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
        final nextId = _mostRecentlyActiveOther(serverId);

        String? promotedId;
        if (nextId != null) {
          final nextContext = _contexts[nextId]!;
          final nextWasBackgrounding =
              nextContext.state == ServerContextState.backgrounding;
          _cancelBackgroundingTimer(nextId);
          try {
            await _ensureActive(nextContext);
            promotedId = nextId;
          } on Object catch (e, st) {
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
      _lastActiveTick.remove(serverId);

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

    await _command(() async {
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
          } on Object catch (e, st) {
            _logError('backgrounding of server $previousId failed', e, st);
            // Restore `previous` to active if we already backgrounded it —
            // it must remain the sole active server per the invariant.
            _cancelBackgroundingTimer(previousId);
            if (previous.state == ServerContextState.backgrounding) {
              try {
                await previous.activate();
              } on Object catch (e3, st3) {
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
            } on Object catch (e2, st2) {
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
    // Teardown waits for the tail, which includes a running command; called
    // from inside one it would wait on itself.
    _assertOutsideCommand();
    if (_disposed) return;
    _disposed = true;

    // Every command queued before this call still runs; teardown waits for
    // them so it never interleaves with one. A command's failure reaches its
    // own caller, never the tail.
    await _tail;

    for (final timer in _backgroundingTimers.values) {
      timer.cancel();
    }
    _backgroundingTimers.clear();

    for (final context in _contexts.values) {
      await context.dispose();
    }
    _contexts.clear();
    _configs.clear();
    _lastActiveTick.clear();
    _activeServerId = null;

    await _activeContextController.close();
    await _contextsController.close();

    _isInitialized = false;
  }

  /// The connected server other than [excludedId] that was active most
  /// recently, or null if there is no other connected server.
  ///
  /// Servers that have never been active in their current connection carry
  /// no tick and rank below every server that has. Ties — which is the
  /// common case, since a monitoring server that was never activated is
  /// the norm — fall back to insertion order, because [_contexts] is
  /// insertion-ordered and the fold keeps the incumbent on a non-strict
  /// comparison.
  String? _mostRecentlyActiveOther(String excludedId) {
    final candidates = _contexts.keys.where((id) => id != excludedId);
    if (candidates.isEmpty) return null;

    return candidates.reduce(
      (best, id) => (_lastActiveTick[id] ?? -1) > (_lastActiveTick[best] ?? -1)
          ? id
          : best,
    );
  }

  /// Restores [config]'s context into [ServerContextState.monitoring] and
  /// registers it, returning whether it restored. A failed restore is
  /// logged, its context released, and the server persisted as
  /// disconnected; a key store that could not be reached rethrows instead
  /// and leaves the persisted state alone (#428).
  Future<bool> _restoreIntoMonitoring(ServerConfig config) async {
    final context = _contextFactory(config);
    try {
      await context.activate(); // initializing → active
      await context.background(); // active → backgrounding
      await context.suspend(); // backgrounding → monitoring
      _contexts[config.id] = context;
      _configs[config.id] = config;
      return true;
    } catch (e, st) {
      _logError('restore of server ${config.id} failed', e, st);
      await _disposeQuietly(context);
      if (e is EncryptionKeyUnavailableError) rethrow;
      await _updateStateQuietly(config.id, ConnectionState.disconnected);
      return false;
    }
  }

  /// Promotes the first of [serverIds], each a context restored into
  /// [ServerContextState.monitoring], that activates, returning whether one
  /// did. One that fails is logged, released, and persisted as
  /// disconnected; a key store that could not be reached rethrows instead
  /// and leaves the persisted state alone (#428).
  Future<bool> _promoteFirst(List<String> serverIds) async {
    for (final id in serverIds) {
      try {
        await _ensureActive(_contexts[id]!);
        await _commitActive(id);
        return true;
      } catch (e, st) {
        _logError('activating restored server $id failed', e, st);
        await _disposeQuietly(_contexts.remove(id)!);
        _configs.remove(id);
        _lastActiveTick.remove(id);
        if (e is EncryptionKeyUnavailableError) rethrow;
        await _updateStateQuietly(id, ConnectionState.disconnected);
      }
    }
    return false;
  }

  /// [configs] in the order [initialize] tries them: the server persisted
  /// as active first, then by [ServerConfig.lastActiveAt], newest first.
  /// Servers never active come last. The sort is stable, so ties keep the
  /// repository's order.
  static List<ServerConfig> _byRecency(Iterable<ServerConfig> configs) {
    int rank(ServerConfig config) => config.isActive ? 0 : 1;
    final sorted = configs.toList();
    mergeSort(
      sorted,
      compare: (a, b) {
        final byActive = rank(a).compareTo(rank(b));
        if (byActive != 0) return byActive;
        final aAt = a.lastActiveAt;
        final bAt = b.lastActiveAt;
        if (aAt == null || bAt == null) {
          return (aAt == null ? 1 : 0) - (bAt == null ? 1 : 0);
        }
        return bAt.compareTo(aAt);
      },
    );
    return sorted;
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
    } on Object catch (e, st) {
      _logError('persisting lastActive for $serverId failed', e, st);
    }

    _activeServerId = serverId;
    _lastActiveTick[serverId] = ++_activationTick;
    _emitActiveChange();
  }

  Future<void> _disposeQuietly(ServerContext context) async {
    try {
      await context.dispose();
    } on Object catch (e, st) {
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
    } on Object catch (e, st) {
      _logError('persisting $state for $serverId failed', e, st);
    }
  }

  void _logError(String what, Object error, StackTrace stackTrace) {
    // Through the logger, so the sinks keep a database error's bound values
    // out of the console and the log file (#463).
    _log.error(what, error: error, stackTrace: stackTrace);
  }

  void _startBackgroundingTimer(String serverId) {
    _cancelBackgroundingTimer(serverId);

    final prefs = _cachedPreferences;
    // TODO(server-config-override): read per-server override from repo
    const int? configOverride = null;
    final timeoutSeconds =
        configOverride ??
        (prefs?.backgroundingTimeoutSeconds(isDesktop: _isDesktop) ??
            (_isDesktop ? 900 : 300));

    final generation = _bumpTimerGeneration(serverId);
    // Outside the command that started it, so an expiry always queues as a
    // command of its own, even one that fires while that command still runs
    // (see class docs).
    final zone = _outsideCommands();
    _backgroundingTimers[serverId] = zone.createTimer(
      Duration(seconds: timeoutSeconds),
      zone.bindCallbackGuarded(
        () => _onBackgroundingTimerExpired(serverId, generation),
      ),
    );
  }

  void _cancelBackgroundingTimer(String serverId) {
    _backgroundingTimers.remove(serverId)?.cancel();
    _bumpTimerGeneration(serverId);
  }

  int _bumpTimerGeneration(String serverId) =>
      _timerGeneration[serverId] = (_timerGeneration[serverId] ?? 0) + 1;

  void _onBackgroundingTimerExpired(String serverId, int generation) {
    _backgroundingTimers.remove(serverId);
    unawaited(_command(() => _suspendOnExpiry(serverId, generation)));
  }

  /// Suspends [serverId] for the timer of [generation]. Whatever ran while
  /// the expiry waited in the queue may have made it moot: teardown, a
  /// cancel or restart of the timer, or a transition out of backgrounding.
  /// Errors are logged, not thrown: nobody awaits a timer's command.
  Future<void> _suspendOnExpiry(String serverId, int generation) async {
    if (_disposed || _timerGeneration[serverId] != generation) return;
    final context = _contexts[serverId];
    if (context == null || context.state != ServerContextState.backgrounding) {
      return;
    }

    try {
      await context.suspend();
      await _serverRepository.updateConnectionState(
        serverId: serverId,
        newState: ConnectionState.monitoring,
      );
      _emitContextsChange();
    } on Object catch (e, st) {
      _logError('suspending $serverId on timer failed', e, st);
    }
  }

  /// Runs [body] once every command queued before it has finished, and
  /// completes with its outcome. A failure reaches this caller only; the
  /// next command runs regardless.
  ///
  /// Throws [StateError] when called from inside a running command, which
  /// would otherwise wait on itself forever.
  Future<T> _command<T>(Future<T> Function() body) {
    _assertOutsideCommand();
    final result = _tail.then((_) async {
      final token = Object();
      _running = token;
      try {
        // zoneValues only: no error zone, so the body's errors still reach
        // the returned future.
        return await runZoned(body, zoneValues: {_commandZoneKey: token});
      } finally {
        _running = null;
      }
    });
    _tail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  void _assertOutsideCommand() {
    final token = Zone.current[_commandZoneKey];
    if (token != null && identical(token, _running)) {
      throw StateError(
        'Re-entrant orchestrator call from inside a running lifecycle '
        'command.',
      );
    }
  }

  /// The nearest zone enclosing [Zone.current] that isn't a command's. Zone
  /// values are inherited and the root zone has none, so the walk ends.
  static Zone _outsideCommands() {
    var zone = Zone.current;
    while (zone[_commandZoneKey] != null) {
      zone = zone.parent!;
    }
    return zone;
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
    } on Object catch (_) {
      return false;
    }
  }
}
