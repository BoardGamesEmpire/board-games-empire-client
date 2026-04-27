import 'package:get_it/get_it.dart';
import 'package:interfaces/orchestration.dart';

/// GetIt-based implementation of [DependencyContainer].
///
/// Each instance wraps a private [GetIt] created via [GetIt.asNewInstance()],
/// guaranteeing full isolation between server contexts. Registrations in one
/// container are invisible to all others.
class DependencyContainerImpl implements DependencyContainer {
  DependencyContainerImpl() : _getIt = GetIt.asNewInstance();

  final GetIt _getIt;
  bool _disposed = false;

  @override
  void registerSingleton<T extends Object>(T instance) {
    _assertNotDisposed();
    _getIt.registerSingleton<T>(instance);
  }

  @override
  void registerLazySingleton<T extends Object>(T Function() factory) {
    _assertNotDisposed();
    _getIt.registerLazySingleton<T>(factory);
  }

  @override
  void registerFactory<T extends Object>(T Function() factory) {
    _assertNotDisposed();
    _getIt.registerFactory<T>(factory);
  }

  @override
  T get<T extends Object>() {
    _assertNotDisposed();
    return _getIt.get<T>();
  }

  @override
  bool isRegistered<T extends Object>() => _getIt.isRegistered<T>();

  /// registered singletons need to be wrapped with GetIt's DisposableWhen mechanism or implement GetIt's own disposable interface
  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    // TODO: iterate over registered singletons and call their dispose methods if they implement DisposableWhen
    // or GetIt's disposable interface, then clear all registrations.

    // GetIt.reset disposes all singletons that implement DisposableWhen/dispose
    // and removes all registrations.
    await _getIt.reset(dispose: true);
  }

  void _assertNotDisposed() {
    if (_disposed) {
      throw StateError(
        'DependencyContainer has been disposed and cannot be used.',
      );
    }
  }
}
