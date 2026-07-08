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

  /// Wraps an externally created [getIt] instance.
  ///
  /// The composition-root seam for injectable adoption (#61/#72):
  /// injectable's generated `init` is an extension on [GetIt], so a
  /// composition root creates the instance itself (always via
  /// [GetIt.asNewInstance] — never the global [GetIt.instance]), runs the
  /// generated init on it, and wraps it here so consumers keep the
  /// [DependencyContainer] abstraction. Registrations are visible in both
  /// directions across the wrapper boundary.
  ///
  /// The wrapper is the instance's lifecycle owner, not a view: [dispose]
  /// resets the wrapped instance, firing every dispose callback supplied
  /// at registration.
  ///
  /// Throws [ArgumentError] if [getIt] is the global `GetIt.instance`.
  /// This is a runtime check in **all** build modes, not an assert:
  /// release strips asserts, and wrapping the global instance would
  /// *silently* leak registrations into global state and break scope
  /// isolation — a corruption worth failing loudly everywhere, and the
  /// check runs once per container build, never on a hot path.
  DependencyContainerImpl.fromGetIt(GetIt getIt) : _getIt = getIt {
    if (identical(getIt, GetIt.instance)) {
      throw ArgumentError.value(
        getIt,
        'getIt',
        'DependencyContainerImpl.fromGetIt must wrap a GetIt.asNewInstance(); '
            'the global GetIt.instance leaks registrations into global state and '
            'breaks scope isolation.',
      );
    }
  }

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
