import 'dart:async';

// get_it exports a Disposable of its own, which BGE services do not
// implement. Every Disposable named in this file is the interfaces one.
import 'package:get_it/get_it.dart' show GetIt;
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
  /// at registration. Only registrations made through this wrapper get the
  /// [Disposable] default: a [Disposable] registered directly on [getIt],
  /// as injectable's generated code registers, is closed only through a
  /// callback it supplies itself (#61).
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
    _getIt.registerSingleton<T>(
      instance,
      // An explicit callback wins. Otherwise the instance is known here,
      // so only a Disposable one gets the default (#254), and one that is
      // not is registered with no callback, exactly as before. That also
      // keeps get_it's assertion against a callback on its own Disposable
      // type out of reach for third-party instances.
      dispose:
          dispose ??
          (instance is Disposable ? (_) => instance.onDispose() : null),
    );
  }

  @override
  void registerLazySingleton<T extends Object>(
    T Function() factory, {
    FutureOr<void> Function(T instance)? dispose,
  }) {
    _assertNotDisposed();
    _getIt.registerLazySingleton<T>(
      factory,
      dispose: dispose ?? _closeIfDisposable,
    );
  }

  /// The lazy singleton's default when no callback was given (#254):
  /// closes the instance through [Disposable.onDispose] if it is
  /// [Disposable].
  ///
  /// The check runs on the instance, not on the registered type, so a
  /// service registered under an interface that is not itself [Disposable]
  /// is still closed. GetIt calls it only for an instance that exists: a
  /// lazy singleton nobody resolved is not built in order to be closed.
  static Future<void> _closeIfDisposable(Object instance) async {
    if (instance is Disposable) await instance.onDispose();
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

  /// False from the moment [dispose] starts. GetIt keeps every
  /// registration until the last dispose callback returns, while [get]
  /// already refuses, and a caller that checks first must not be told
  /// otherwise: a user-scope view falls through to its parent on false
  /// (#218).
  @override
  bool isRegistered<T extends Object>() =>
      !_disposed && _getIt.isRegistered<T>();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    // GetIt.reset(dispose: true) runs the dispose callback of every
    // singleton and every created lazy singleton, in reverse registration
    // order, then removes all registrations. A registration that came
    // without a callback was given the Disposable default when it was
    // made, so a Disposable service needs nothing from its installer.
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
