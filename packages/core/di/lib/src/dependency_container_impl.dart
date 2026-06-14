import 'dart:async';

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
  void registerSingleton<T extends Object>(
    T instance, {
    FutureOr<void> Function(T instance)? dispose,
  }) {
    _assertNotDisposed();
    _getIt.registerSingleton<T>(instance, dispose: dispose);
  }

  @override
  void registerLazySingleton<T extends Object>(
    T Function() factory, {
    FutureOr<void> Function(T instance)? dispose,
  }) {
    _assertNotDisposed();
    _getIt.registerLazySingleton<T>(factory, dispose: dispose);
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

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    // GetIt.reset(dispose: true) invokes the dispose callback supplied at
    // registration for every singleton (and every instantiated lazy
    // singleton), then removes all registrations. Services should be
    // registered with `dispose: (s) => s.onDispose()`; shared third-party
    // resources (e.g. Dio) with their own teardown callback.
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
