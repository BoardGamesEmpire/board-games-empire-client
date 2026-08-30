import 'dart:async';

import 'package:di/di.dart' show UserScopeHost;
import 'package:interfaces/orchestration.dart';

/// The web server scope's [DependencyContainer], as consumers see it (#137).
///
/// Reads check the open user-session scope first and fall through to the
/// origin scope; writes always land in the origin scope. That fall-through is
/// not a convenience — it is what makes the per-user tier *reachable*.
///
/// Everything that consumes a user-scoped service resolves it from
/// `ActiveServer.container`: the household list, detail and create routes,
/// the home drawer's gate, and the re-hydrate triggers. Native satisfies them
/// because its `ActiveServer.container` is `ServerContextImpl`'s swappable
/// facade, which already resolves child-first. Web's was the raw origin
/// container, so a user scope could be opened, installed and torn down
/// correctly and *no consumer would ever see into it* — the acceptance test
/// for the scope would pass over an app that still showed nothing.
///
/// The child-first lookup itself lives on [UserScopeHost]
/// ([UserScopeHost.maybeGet] / [UserScopeHost.scopeHasRegistration]), shared
/// with native's facade rather than written out twice (#327). What is here is
/// the part that genuinely differs: web's parent is fixed for the life of the
/// app — no orchestrator, no server switching, nothing to suspend — so there
/// is no swappable inner container and no state machine to gate on.
///
/// The [host] must be the same one the scope's `UserSessionScope` drives;
/// `bootstrapWebServerScope` is the only place that builds either, so they
/// cannot drift apart.
class WebServerScopeContainer implements DependencyContainer {
  /// Wraps [base], the origin scope, resolving through [host] first.
  ///
  /// [closeSession] is the session holder's own teardown, when the scope has
  /// one. [dispose] prefers it over closing [host] directly so the teardown
  /// lands on the holder's serialization chain instead of racing it — see
  /// [dispose]. Null means there is no holder, and the host is closed
  /// directly because nothing else can be mutating it.
  WebServerScopeContainer({
    required this._base,
    required this._host,
    this._closeSession,
  });

  final DependencyContainer _base;
  final UserScopeHost _host;
  final Future<void> Function()? _closeSession;

  @override
  T get<T extends Object>() => _host.maybeGet<T>() ?? _base.get<T>();

  @override
  bool isRegistered<T extends Object>() =>
      _host.scopeHasRegistration<T>() || _base.isRegistered<T>();

  /// Registrations land in the **origin** scope. The user-session scope is
  /// only ever written through the view its installers are handed, so a
  /// stray registration through this handle cannot silently acquire a
  /// per-user lifetime.
  @override
  void registerSingleton<T extends Object>(
    T instance, {
    FutureOr<void> Function(T instance)? dispose,
  }) => _base.registerSingleton<T>(instance, dispose: dispose);

  @override
  void registerLazySingleton<T extends Object>(
    T Function() factory, {
    FutureOr<void> Function(T instance)? dispose,
  }) => _base.registerLazySingleton<T>(factory, dispose: dispose);

  @override
  void registerFactory<T extends Object>(T Function() factory) =>
      _base.registerFactory<T>(factory);

  /// Disposes the whole scope: the user-session scope first, then the origin
  /// scope.
  ///
  /// Order matters and is the same as native's (`_SwappableContainer`):
  /// per-user services hold resources owned by the origin scope — the
  /// `ServerDatabase` above all — so they must release before it closes
  /// underneath them. Both disposals always run; the first error, if any, is
  /// rethrown.
  ///
  /// The user scope goes down through the session holder's own teardown
  /// where there is one, rather than by closing the host here. Closing the
  /// host directly would step outside the holder's serialization chain: the
  /// shell fires `activate` unawaited from its auth listener, so a dispose
  /// arriving mid-activation would dispose the half-built child out from
  /// under the installer loop, and the remaining installers would fail
  /// against a disposed container. Queued behind the activation instead, the
  /// session finishes and is then torn down.
  @override
  Future<void> dispose() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await (_closeSession ?? _host.close)();
    } catch (e, s) {
      firstError = e;
      firstStackTrace = s;
    }
    try {
      await _base.dispose();
    } catch (e, s) {
      firstError ??= e;
      firstStackTrace ??= s;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }
}
