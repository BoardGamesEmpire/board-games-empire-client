import 'dart:async';

/// Abstraction over a scoped dependency injection container.
///
/// Two scopes exist. The app-scope **root container** is device-global,
/// built once per boot by the platform composition root
/// (`PlatformBootstrap.createRootContainer`, #72) and holds services that
/// outlive any single server (client version, feedback, connectivity).
/// Per-server containers are owned by their [ServerContext] — exactly one
/// each — providing full isolation between server scopes. Implementations
/// use `GetIt.asNewInstance()` to guarantee this isolation; root services
/// reach per-server containers by explicit constructor injection at
/// context construction, never parent-scope lookup (#38).
///
/// ## Disposal
///
/// Disposing a production container closes every singleton, and every
/// lazy singleton that was created, in reverse registration order. Each is
/// closed through the `dispose` callback given at registration or, when
/// none was given, through [Disposable.onDispose] if the instance is
/// [Disposable] (#254). Implementing [Disposable] is therefore enough for
/// a service to be torn down with its scope. The flip side: a container
/// owns every [Disposable] registered in it without a callback, so
/// registering an instance something else owns and ends (another scope, a
/// test harness) needs a `dispose` callback that leaves it open. The same
/// holds within one container: an instance registered under two types
/// without a callback is closed twice.
/// Hand-written test fakes of this interface need not honour the
/// [Disposable] default.
abstract class DependencyContainer {
  /// Retrieves a registered dependency of type [T].
  ///
  /// Throws [StateError] if [T] is not registered in this scope, or if
  /// the container has been disposed.
  T get<T extends Object>();

  /// Registers [instance] as a singleton. The same instance is returned on
  /// every [get] call.
  ///
  /// When the container is disposed, [dispose] is invoked with the
  /// instance. Omit it for a [Disposable] service: the container closes the
  /// instance through [Disposable.onDispose]. Pass it for a type with its
  /// own teardown (e.g. `Dio.close`). An explicit callback replaces the
  /// [Disposable] default rather than running beside it.
  void registerSingleton<T extends Object>(
    T instance, {
    FutureOr<void> Function(T instance)? dispose,
  });

  /// Registers a lazy singleton. [factory] is called once on the first [get]
  /// call and the result is cached for all subsequent calls.
  ///
  /// Use for expensive resources (DB connections, network clients) that should
  /// not be instantiated until first access. Disposal follows
  /// [registerSingleton]'s rule, checked on the created instance rather than
  /// on [T]: [dispose] if given, otherwise [Disposable.onDispose] if the
  /// instance is [Disposable]. Neither runs if the instance was never
  /// created.
  void registerLazySingleton<T extends Object>(
    T Function() factory, {
    FutureOr<void> Function(T instance)? dispose,
  });

  /// Registers [factory] as a factory. A new instance is created on every
  /// [get] call. The container does not track or dispose factory instances.
  void registerFactory<T extends Object>(T Function() factory);

  /// Whether [T] has been registered in this container.
  ///
  /// Never true once [dispose] has started, even while it is still running,
  /// since [get] throws from then on.
  bool isRegistered<T extends Object>();

  /// Disposes all singleton and instantiated lazy singleton instances, each
  /// through its registration's callback or the [Disposable] default (see
  /// the class doc), then resets the container.
  ///
  /// Idempotent — safe to call multiple times.
  Future<void> dispose();
}

/// Marker interface for services that require explicit cleanup.
///
/// Implement this on any service registered as a singleton or lazy singleton
/// that holds resources (DB connections, stream subscriptions, timers, etc.).
/// Implementing it is enough: a [DependencyContainer] closes the service
/// through [onDispose] when its scope is disposed, so the registration needs
/// no `dispose` callback. A service must not close resources it shares with
/// other services (e.g. a shared `Dio`); those are owned and disposed by the
/// container directly.
abstract interface class Disposable {
  Future<void> onDispose();
}
