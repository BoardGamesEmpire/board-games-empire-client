/// Abstraction over a scoped dependency injection container.
///
/// Each [ServerContext] owns exactly one [DependencyContainer] instance,
/// providing full isolation between server scopes. Implementations use
/// [GetIt.asNewInstance()] to guarantee this isolation.
abstract class DependencyContainer {
  /// Retrieves a registered dependency of type [T].
  ///
  /// Throws [StateError] if [T] is not registered in this scope, or if
  /// the container has been disposed.
  T get<T extends Object>();

  /// Registers [instance] as a singleton. The same instance is returned on
  /// every [get] call.
  void registerSingleton<T extends Object>(T instance);

  /// Registers a lazy singleton. [factory] is called once on the first [get]
  /// call and the result is cached for all subsequent calls.
  ///
  /// Use for expensive resources (DB connections, network clients) that should
  /// not be instantiated until first access.
  void registerLazySingleton<T extends Object>(T Function() factory);

  /// Registers [factory] as a factory. A new instance is created on every
  /// [get] call. The container does not track or dispose factory instances.
  void registerFactory<T extends Object>(T Function() factory);

  /// Whether [T] has been registered in this container.
  bool isRegistered<T extends Object>();

  /// Disposes all singleton and instantiated lazy singleton instances that
  /// implement [Disposable], then resets the container.
  ///
  /// Idempotent — safe to call multiple times.
  Future<void> dispose();
}

/// Marker interface for services that require explicit cleanup.
///
/// Implement this on any service registered as a singleton or lazy singleton
/// that holds resources (DB connections, stream subscriptions, timers, etc.).
/// [DependencyContainer.dispose] will call [onDispose] automatically.
abstract interface class Disposable {
  Future<void> onDispose();
}
