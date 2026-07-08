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
abstract class DependencyContainer {
  /// Retrieves a registered dependency of type [T].
  ///
  /// Throws [StateError] if [T] is not registered in this scope, or if
  /// the container has been disposed.
  T get<T extends Object>();

  /// Registers [instance] as a singleton. The same instance is returned on
  /// every [get] call.
  ///
  /// If [dispose] is provided, it is invoked with the instance when the
  /// container is disposed. Use this to release resources held by services
  /// that implement [Disposable] (forward to [Disposable.onDispose]) or by
  /// third-party types with their own teardown (e.g. `Dio.close`). The
  /// callback keeps disposal explicit and order-controlled rather than
  /// relying on a service to clean up a resource it may share with others.
  void registerSingleton<T extends Object>(
    T instance, {
    FutureOr<void> Function(T instance)? dispose,
  });

  /// Registers a lazy singleton. [factory] is called once on the first [get]
  /// call and the result is cached for all subsequent calls.
  ///
  /// Use for expensive resources (DB connections, network clients) that should
  /// not be instantiated until first access. If [dispose] is provided, it is
  /// invoked with the instance when the container is disposed — but only if the
  /// instance was ever created.
  void registerLazySingleton<T extends Object>(
    T Function() factory, {
    FutureOr<void> Function(T instance)? dispose,
  });

  /// Registers [factory] as a factory. A new instance is created on every
  /// [get] call. The container does not track or dispose factory instances.
  void registerFactory<T extends Object>(T Function() factory);

  /// Whether [T] has been registered in this container.
  bool isRegistered<T extends Object>();

  /// Disposes all singleton and instantiated lazy singleton instances,
  /// invoking any [dispose] callback supplied at registration, then resets the
  /// container.
  ///
  /// Idempotent — safe to call multiple times.
  Future<void> dispose();
}

/// Marker interface for services that require explicit cleanup.
///
/// Implement this on any service registered as a singleton or lazy singleton
/// that holds resources (DB connections, stream subscriptions, timers, etc.).
/// Register the service with `dispose: (s) => s.onDispose()` so the
/// [DependencyContainer] tears it down. A service must not close resources it
/// shares with other services (e.g. a shared `Dio`); those are owned and
/// disposed by the container directly.
abstract interface class Disposable {
  Future<void> onDispose();
}
