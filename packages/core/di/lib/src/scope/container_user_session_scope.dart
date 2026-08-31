import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';

import 'user_scope_host.dart';

/// [UserSessionScope] over a **fixed** parent scope (#137).
///
/// The counterpart to `ServerContextImpl`'s adapter, for composition roots
/// that have no context state machine to gate on. Web is the first: it has
/// one origin-scoped container for the life of the app — no orchestrator, no
/// server switching, nothing to suspend — so "can this scope host a session"
/// reduces to "has this holder been disposed".
///
/// It owns the two obligations [UserScopeHost] deliberately leaves to its
/// owner, and nothing else; the mechanism itself stays in the host.
///
/// ## Serialization
///
/// [activate] and [deactivate] run on one chain, so overlapping calls cannot
/// interleave scope mutations — the contract every [UserSessionScope]
/// implementation owes. It is needed in practice, not just on paper: the
/// shell fires both handlers unawaited from its auth listener, so a fast
/// sign-out → sign-in produces exactly that overlap.
///
/// `ServerContextImpl` serializes on the same chain as its state
/// transitions, because there a user-session operation and an activate /
/// suspend must not interleave either. Here there are no transitions to share
/// a chain with, so this holds its own.
///
/// ## Terminal state
///
/// [UserScopeHost.close] ends a session, never the host, so an [activate]
/// after teardown would build a child scope nothing will ever dispose. This
/// holder refuses once [dispose] has run, which is the guard the host's docs
/// require of every owner (native's lives on its container facade).
///
/// Wire [dispose] as the registration's `dispose:` callback so the server
/// scope's teardown ends any live session and closes this permanently:
///
/// ```dart
/// container.registerSingleton<UserSessionScope>(
///   scope,
///   dispose: (s) => (s as ContainerUserSessionScope).dispose(),
/// );
/// ```
class ContainerUserSessionScope implements UserSessionScope {
  /// Creates a holder over [host].
  ///
  /// [host] is shared with the owner's container facade rather than created
  /// here: the facade resolves child-first through the same host
  /// ([UserScopeHost.maybeGet]), and two hosts over one parent would mean two
  /// scopes that each believe they are the session.
  ///
  /// [installers] run in list order on every [activate], against a view whose
  /// registrations land in the user scope while resolution falls through to
  /// the parent. [server] is what they are told about the server; [label]
  /// prefixes the diagnostics this holder emits.
  ContainerUserSessionScope({
    required this._host,
    required List<UserScopeInstaller> installers,
    required this._server,
    this._label = 'ContainerUserSessionScope',
  }) : _installers = List<UserScopeInstaller>.unmodifiable(installers);

  final UserScopeHost _host;
  final List<UserScopeInstaller> _installers;
  final ScopedServer _server;
  final String _label;

  /// Serializes [activate] / [deactivate] / [dispose]; always settled.
  Future<void> _ops = Future<void>.value();

  String? _activeUserId;
  bool _disposed = false;

  @override
  String? get activeUserId => _activeUserId;

  /// Whether [dispose] has run. A disposed holder refuses [activate] and
  /// treats [deactivate] as a no-op.
  bool get isDisposed => _disposed;

  @override
  Future<void> activate(String userId) {
    return _enqueue(() async {
      if (_disposed) {
        throw StateError(
          'Cannot activate a user session for "${_server.serverId}": its '
          'server scope has been disposed.',
        );
      }
      if (_activeUserId == userId) return;

      // A different user's scope without an intervening deactivation: tear
      // it down before building the new one, so a missed pop cannot leak the
      // prior user's services.
      await _teardown();

      await _host.open((view) async {
        for (final installer in _installers) {
          await installer.install(view, _server, userId);
        }
      });
      _activeUserId = userId;
    });
  }

  @override
  Future<void> deactivate() => _enqueue(_teardown);

  /// Ends any live session and closes this holder permanently. Idempotent.
  ///
  /// Terminal, unlike [deactivate]: after this an [activate] throws rather
  /// than building a scope with no owner left to dispose it.
  Future<void> dispose() {
    return _enqueue(() async {
      if (_disposed) return;
      _disposed = true;
      await _teardown();
    });
  }

  /// Chains [op] and keeps the chain settled — a failed operation must not
  /// poison the ones behind it. The caller of [op] still receives the error.
  Future<void> _enqueue(Future<void> Function() op) {
    final result = _ops.then((_) => op());
    _ops = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Disposes the open user scope, if any.
  ///
  /// Mirrors `ServerContextImpl`'s guarded teardown: a throwing `dispose:`
  /// callback is reported in debug and swallowed, so the session still ends
  /// and the next activation starts clean. A sign-out that failed because
  /// some repository's teardown threw would be the worse outcome — the
  /// user would still be signed in to a scope nobody can use.
  Future<void> _teardown() async {
    _activeUserId = null;
    if (!_host.isActive) return;
    try {
      await _host.close();
    } catch (error) {
      assert(() {
        debugPrint(
          '$_label: user-scope disposal threw during session deactivation '
          '(suppressed; the session still ended): $error',
        );
        return true;
      }());
    }
  }
}
