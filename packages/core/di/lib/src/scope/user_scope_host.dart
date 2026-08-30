import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:interfaces/orchestration.dart';

import '../dependency_container_impl.dart';

/// The per-user child-scope mechanism (#135), extracted so any composition
/// root can host a user session (#289).
///
/// A user-session scope is a child of some parent scope: registrations made
/// while it is open land in the child, resolution falls through to the
/// parent, and closing it disposes everything the child holds — running the
/// `dispose:` callback of every registration, which is how per-user
/// repositories close their vended streams.
///
/// This class owns *only* that mechanism. It deliberately knows nothing
/// about [UserScopeInstaller], [ServerConfig], user ids, or the state of the
/// scope that hosts it — those belong to the owner:
///
/// - `ServerContextImpl` keeps its context-state machine, its serialized
///   scope-operation chain, and the `UserSessionScope` adapter it registers,
///   and delegates the mechanism here;
/// - [ContainerUserSessionScope] does the same over a fixed parent, which is
///   the shape web's origin-scoped container needs (#137).
///
/// Two copies of this lifecycle is exactly what #289 exists to prevent: the
/// contract is subtle enough — partial scope discarded on installer failure,
/// teardown errors never masking the failure that caused them — that copies
/// would drift.
///
/// Nothing here is serialized. Overlapping [open]/[close] calls are the
/// owner's problem to prevent, because the owner is where the ordering
/// constraint actually lives (native serializes user-session operations on
/// the same chain as its state transitions).
///
/// For the same reason this host has **no terminal state**: [close] ends a
/// session, never the host, and an [open] after the owner has torn itself
/// down would build a child scope nothing will ever dispose. Rejecting that
/// is the owner's job, and the owner is the only thing that knows it has
/// been torn down. Both owners now do it, in about three lines each:
/// `ServerContextImpl` guards on its container facade before delegating
/// here, and [ContainerUserSessionScope] — web's holder (#137) — refuses
/// once its own `dispose` has run. #327 weighed moving the guard in here and
/// the second implementation argued against it: the owners are where the
/// knowledge is, and neither wanted the primitive to hold it.
class UserScopeHost {
  UserScopeHost({
    required this._parent,
    this._childFactory = DependencyContainerImpl.new,
    this._label = 'UserScopeHost',
  });

  /// The parent scope, resolved on every call rather than captured: native's
  /// parent is a swappable inner container that a suspend/re-activate cycle
  /// replaces underneath a stable facade.
  final DependencyContainer Function() _parent;

  final DependencyContainer Function() _childFactory;

  /// Prefixed onto the diagnostics this host emits, so a suppressed teardown
  /// error can be traced to its owner (e.g. `ServerContext(<id>)`).
  final String _label;

  DependencyContainer? _scope;

  /// Whether a user-session scope is currently open.
  bool get isActive => _scope != null;

  /// Resolves [T] from the open user-session scope, or null when no scope is
  /// open or the open one holds no registration for [T].
  ///
  /// This and [scopeHasRegistration] are the read half an owner's container
  /// facade needs to resolve child-first and fall through to its own parent.
  /// Both owners want exactly this — `ServerContextImpl`'s swappable
  /// container and web's holder over its origin scope (#137) — which is why
  /// the fall-through is expressed here once rather than written out at each
  /// facade (#327).
  ///
  /// Typed lookups rather than a getter returning the child container: a
  /// holder given the container could register into it or dispose it behind
  /// this host's back, leaving the host believing a scope is open that has
  /// already been torn down. The lifecycle is this host's alone.
  T? maybeGet<T extends Object>() {
    final scope = _scope;
    if (scope == null || !scope.isRegistered<T>()) return null;
    return scope.get<T>();
  }

  /// Whether the open user-session scope holds a registration for [T].
  /// False when no scope is open.
  bool scopeHasRegistration<T extends Object>() =>
      _scope?.isRegistered<T>() ?? false;

  /// Opens a fresh user-session scope and runs [install] against a container
  /// **view**: registrations land in the new child scope while resolution
  /// checks the child first, then falls through to the parent — so an
  /// installer resolves parent-lifetime resources and services a preceding
  /// installer registered through one handle.
  ///
  /// The scope is attached before [install] runs, so a caller resolving
  /// through the owner facade mid-install sees the partial scope.
  ///
  /// Throws [StateError] if a scope is already open; the caller closes the
  /// previous one first. If [install] throws, the partial scope is discarded
  /// (the parent is untouched) and the error propagates unchanged — a later
  /// [open] retries from a clean scope. A teardown that throws while
  /// discarding is logged in debug and suppressed: the installer error is
  /// the one the caller has to act on.
  Future<void> open(
    Future<void> Function(DependencyContainer view) install,
  ) async {
    if (_scope != null) {
      throw StateError(
        'A user-session scope is already active; deactivate it before '
        'activating another.',
      );
    }

    final child = _childFactory();
    _scope = child;
    try {
      await install(_UserScopeView(user: child, base: _parent));
    } catch (_) {
      try {
        await close();
      } catch (teardownError) {
        assert(() {
          debugPrint(
            '$_label: user-scope reset after a failed session activation '
            'threw (suppressed in favor of the original installer error): '
            '$teardownError',
          );
          return true;
        }());
      }
      rethrow;
    }
  }

  /// Disposes the open user-session scope — every registration's `dispose:`
  /// callback runs — and detaches it. A no-op when none is open.
  ///
  /// The scope is detached *before* its disposal is awaited, so a throwing
  /// dispose callback still leaves this host closed and reusable.
  Future<void> close() async {
    final scope = _scope;
    _scope = null;
    if (scope != null) await scope.dispose();
  }
}

/// The container view handed to a user-scope installer (#135): registrations
/// land in the user-session scope; resolution checks the user scope first,
/// then falls through to the parent scope, so an installer can resolve
/// parent-lifetime resources and services a preceding installer registered
/// through one handle.
///
/// Lifecycle is owned by the [UserScopeHost] — the view exposes no teardown.
class _UserScopeView implements DependencyContainer {
  _UserScopeView({required this._user, required this._base});

  final DependencyContainer _user;

  /// Getter rather than a captured reference: the parent may be a swappable
  /// inner container, resolved at call time.
  final DependencyContainer Function() _base;

  @override
  T get<T extends Object>() =>
      _user.isRegistered<T>() ? _user.get<T>() : _base().get<T>();

  @override
  bool isRegistered<T extends Object>() =>
      _user.isRegistered<T>() || _base().isRegistered<T>();

  @override
  void registerSingleton<T extends Object>(
    T instance, {
    FutureOr<void> Function(T instance)? dispose,
  }) => _user.registerSingleton<T>(instance, dispose: dispose);

  @override
  void registerLazySingleton<T extends Object>(
    T Function() factory, {
    FutureOr<void> Function(T instance)? dispose,
  }) => _user.registerLazySingleton<T>(factory, dispose: dispose);

  @override
  void registerFactory<T extends Object>(T Function() factory) =>
      _user.registerFactory<T>(factory);

  @override
  Future<void> dispose() {
    throw UnsupportedError(
      'The user-scope view must not be disposed by installers; the '
      'user-session scope lifecycle is owned by its host (#135).',
    );
  }
}
