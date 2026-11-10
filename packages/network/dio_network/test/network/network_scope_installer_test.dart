import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';

import '../support/in_memory_session_tombstone_store.dart';

ServerConfig _makeConfig() => ServerConfig(
  id: 'server-local-1',
  displayName: 'Test Server',
  serverUrl: 'https://api.example.com',
  connectionState: ConnectionState.disconnected,
  bgeServerId: '550e8400-e29b-41d4-a716-446655440000',
  cachedIdentity: const ServerIdentity(
    serverId: '550e8400-e29b-41d4-a716-446655440000',
    issuer: 'https://api.example.com',
    wellKnownSchemaVersion: 1,
    name: 'Test BGE Server',
    deviceAuthorizationEndpoint: '/api/auth/device',
    authBasePath: '/api/auth',
    sessionEndpoint: '/api/auth/get-session',
    signOutEndpoint: '/api/auth/sign-out',
    passkeySupported: true,
    twoFactorSupported: true,
    anonymousAuthSupported: true,
  ),
  lastIdentityFetchedAt: DateTime.now().toUtc(),
);

class _FakeProviderBrowser implements ProviderSignInBrowser {
  const _FakeProviderBrowser({this.isSupported = true});

  @override
  final bool isSupported;

  @override
  Future<Uri?> authenticate({
    required Uri url,
    required String callbackScheme,
  }) => throw UnimplementedError();
}

NetworkScopeInstaller installer({
  ProviderSignInBrowser providerBrowser = const _FakeProviderBrowser(),
}) => NetworkScopeInstaller(
  sessionTombstones: InMemorySessionTombstoneStore(),
  providerBrowser: providerBrowser,
);

void main() {
  late DependencyContainerImpl container;

  setUp(() => container = DependencyContainerImpl());

  tearDown(() => container.dispose());

  group('NetworkScopeInstaller', () {
    test('registers the full network stack for the scope', () async {
      await installer().install(container, _makeConfig());

      expect(container.isRegistered<TokenStorageService>(), isTrue);
      expect(container.isRegistered<DioFactory>(), isTrue);
      expect(container.isRegistered<ClockService>(), isTrue);
      expect(container.isRegistered<Dio>(), isTrue);
      expect(container.isRegistered<AuthRepository>(), isTrue);
    });

    test('registered ClockService is the skew-corrected estimator', () async {
      await installer().install(container, _makeConfig());

      // The native stack must register the estimator (fed by the Dio
      // interceptor), not the pass-through null object. Web registers the
      // same estimator since #118, so no container registers the null
      // object — it survives as a constructor default, not as a scope's
      // clock.
      expect(container.get<ClockService>(), isA<ServerSkewClockService>());
    });

    test('hands the tombstone store to the token storage, keyed by the '
        'server-vended id', () async {
      final tombstones = InMemorySessionTombstoneStore();
      final config = _makeConfig();
      expect(config.id, isNot(config.bgeServerId));
      await NetworkScopeInstaller(
        sessionTombstones: tombstones,
        providerBrowser: const _FakeProviderBrowser(),
      ).install(container, config);

      // The marker is written ahead of the keychain delete. There is no
      // keychain plugin in the test host, so the delete itself throws.
      try {
        await container.get<TokenStorageService>().clear();
      } on Object {
        // Expected: only the marker is under test here.
      }

      expect(tombstones.revoked, {config.bgeServerId});
    });

    test(
      'passes its browser to the AuthRepository it registers (#583)',
      () async {
        await installer().install(container, _makeConfig());
        expect(
          container.get<AuthRepository>().providerSignInAvailability,
          isA<ProviderSignInAvailable>(),
        );
      },
    );

    test('a browser that is not supported makes provider sign-in '
        'unavailable (#583)', () async {
      await installer(
        providerBrowser: const _FakeProviderBrowser(isSupported: false),
      ).install(container, _makeConfig());
      expect(
        container.get<AuthRepository>().providerSignInAvailability,
        isA<ProviderSignInUnsupportedDevice>(),
      );
    });

    test('disposes the AuthRepository with the container — its auth-state '
        'stream completes', () async {
      await installer().install(container, _makeConfig());
      final auth = container.get<AuthRepository>();
      final completes = expectLater(
        auth.watchAuthState(),
        emitsThrough(emitsDone),
      );

      await container.dispose();

      await completes;
    });

    test('shared Dio uses the config server URL as base', () async {
      await installer().install(container, _makeConfig());

      expect(container.get<Dio>().options.baseUrl, 'https://api.example.com');
    });

    test('is registration-equivalent to registerServerNetwork', () async {
      // Guard against the adapter drifting from the function it wraps.
      final direct = DependencyContainerImpl();
      addTearDown(direct.dispose);
      registerServerNetwork(
        container: direct,
        config: _makeConfig(),
        sessionTombstones: InMemorySessionTombstoneStore(),
      );

      await installer().install(container, _makeConfig());

      expect(
        container.isRegistered<TokenStorageService>(),
        direct.isRegistered<TokenStorageService>(),
      );
      expect(
        container.isRegistered<DioFactory>(),
        direct.isRegistered<DioFactory>(),
      );
      expect(container.isRegistered<Dio>(), direct.isRegistered<Dio>());
      expect(
        container.isRegistered<ClockService>(),
        direct.isRegistered<ClockService>(),
      );
      expect(
        container.isRegistered<AuthRepository>(),
        direct.isRegistered<AuthRepository>(),
      );
    });
  });
}
