import 'dart:async';

import 'package:interfaces/orchestration.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

void main() {
  group('ServerOnboardingDeps.from', () {
    final wellKnownClient = _FakeWellKnownClient();
    final versionNegotiator = _FakeVersionNegotiator();
    final connectivityService = _FakeConnectivityService();
    const buildInfo = BuildInfo.unknown;

    _MapContainer fullContainer() => _MapContainer()
      ..registerSingleton<WellKnownClient>(wellKnownClient)
      ..registerSingleton<VersionNegotiator>(versionNegotiator)
      ..registerSingleton<ConnectivityService>(connectivityService)
      ..registerSingleton<BuildInfo>(buildInfo);

    test('takes each member from the container', () {
      final deps = ServerOnboardingDeps.from(fullContainer());

      expect(deps.wellKnownClient, same(wellKnownClient));
      expect(deps.versionNegotiator, same(versionNegotiator));
      expect(deps.connectivityService, same(connectivityService));
      expect(deps.buildInfo, same(buildInfo));
    });

    test("throws the container's error when a member is absent", () {
      final container = fullContainer()..unregister<ConnectivityService>();

      expect(
        () => ServerOnboardingDeps.from(container),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('ConnectivityService'),
          ),
        ),
      );
    });
  });
}

/// The slice of a [DependencyContainer] `from` reads: singletons by type,
/// and a `get` that names the type it could not find, as the real
/// container's does.
class _MapContainer implements DependencyContainer {
  final _instances = <Type, Object>{};

  @override
  T get<T extends Object>() {
    final instance = _instances[T];
    if (instance == null) throw StateError('$T is not registered');
    return instance as T;
  }

  @override
  void registerSingleton<T extends Object>(
    T instance, {
    FutureOr<void> Function(T instance)? dispose,
  }) => _instances[T] = instance;

  void unregister<T extends Object>() => _instances.remove(T);

  @override
  bool isRegistered<T extends Object>() => _instances.containsKey(T);

  @override
  void registerLazySingleton<T extends Object>(
    T Function() factory, {
    FutureOr<void> Function(T instance)? dispose,
  }) => throw UnimplementedError();

  @override
  void registerFactory<T extends Object>(T Function() factory) =>
      throw UnimplementedError();

  @override
  Future<void> dispose() async {}
}

class _FakeWellKnownClient implements WellKnownClient {
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeVersionNegotiator implements VersionNegotiator {
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeConnectivityService implements ConnectivityService {
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
