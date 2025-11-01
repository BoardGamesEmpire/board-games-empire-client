/// Abstraction over get_it or alternative dependency injection containers
/// allowing ServerContext to remain agnostic to specific DI implementation
abstract class DependencyContainer {
  /// Retrieves a registered dependency of type T from this container's scope
  ///
  /// Throws if T is not registered in this scope
  T get<T extends Object>();

  /// Registers a singleton instance within this container's scope
  void registerSingleton<T extends Object>(T instance);

  /// Registers a factory function for lazy instantiation within this scope
  void registerFactory<T extends Object>(T Function() factory);

  /// Disposes all disposable dependencies and clears the container
  Future<void> dispose();
}
