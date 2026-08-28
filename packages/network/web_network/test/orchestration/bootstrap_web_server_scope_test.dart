import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:web_network/src/auth/web_auth_repository_impl.dart';
import 'package:web_network/src/orchestration/bootstrap_web_server_scope.dart';

class _MockWellKnownClient extends Mock implements WellKnownClient {}

const _kOrigin = 'https://bge.example.com';
const _kAuthBase = '/api/auth';

ServerIdentity _identity() => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: _kOrigin,
  wellKnownSchemaVersion: 1,
  name: 'Test BGE Server',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: '$_kAuthBase/get-session',
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
  strategies: const [
    EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '$_kAuthBase/sign-in/email',
      signUpEndpoint: '$_kAuthBase/sign-up/email',
    ),
  ],
);

void main() {
  late _MockWellKnownClient wellKnownClient;
  // Assigned by successful runs so tearDown can dispose the created scope's
  // container; stays null when the fetch fails.
  ActiveServerScope? scope;

  setUp(() {
    wellKnownClient = _MockWellKnownClient();
    scope = null;
  });

  tearDown(() async {
    await scope?.active?.container.dispose();
  });

  Future<ActiveServerScope> bootstrap({
    WebServerScopeInstall? installStorage,
  }) => bootstrapWebServerScope(
    wellKnownClient: wellKnownClient,
    // Uri.base has no origin on the VM, so the origin is injected; production
    // defaults to WebDioFactory.currentOrigin (the browser address bar).
    originProvider: () => _kOrigin,
    installStorage: installStorage,
  );

  void stubFetchSuccess() =>
      when(() => wellKnownClient.fetchIdentity(any()))
          .thenAnswer((_) async => _identity());

  group('bootstrapWebServerScope', () {
    test('fetches the origin identity and returns a scope with a non-null '
        'active server', () async {
      stubFetchSuccess();

      scope = await bootstrap();

      expect(scope!.active, isNotNull);
      verify(() => wellKnownClient.fetchIdentity(_kOrigin)).called(1);
    });

    test('sources the active server id and display name from the fetched '
        'identity', () async {
      stubFetchSuccess();

      scope = await bootstrap();

      final active = scope!.active!;
      expect(active.serverId, 'server-uuid-1');
      expect(active.displayName, 'Test BGE Server');
      expect(active.identity, _identity());
    });

    test(
      'populates the scope container with a resolvable AuthRepository',
      () async {
        stubFetchSuccess();

        scope = await bootstrap();

        expect(
          scope!.active!.container.get<AuthRepository>(),
          isA<WebAuthRepositoryImpl>(),
        );
      },
    );

    test(
      'builds the server Dio against the same origin used for the fetch',
      () async {
        stubFetchSuccess();

        scope = await bootstrap();

        final dio = scope!.active!.container.get<Dio>();
        expect(dio.options.baseUrl, _kOrigin);
        verify(() => wellKnownClient.fetchIdentity(_kOrigin)).called(1);
      },
    );

    test(
      'propagates well-known fetch failures unchanged (no scope built)',
      () async {
        when(() => wellKnownClient.fetchIdentity(any())).thenThrow(
          const WellKnownUnreachableException(
            serverUrl: _kOrigin,
            message: 'boom',
          ),
        );

        await expectLater(
          bootstrap(),
          throwsA(isA<WellKnownUnreachableException>()),
        );
        // The fetch runs before any container is created, so a failure leaks
        // nothing: `scope` stays null and tearDown disposes nothing.
        expect(scope, isNull);
      },
    );
  });

  // #288 D3: the seam `web_platform` uses to register the drift/wasm data
  // layer without this package depending on a browser-only library. The
  // storage side is tested in `web_storage`; what matters here is the
  // contract — what it is handed, when, and what happens when it fails.
  group('bootstrapWebServerScope storage seam (#288 D3)', () {
    test(
      'is omitted by default — the storage-less scope still builds',
      () async {
        stubFetchSuccess();

        scope = await bootstrap();

        expect(scope!.active, isNotNull);
      },
    );

    test(
      'runs with the identity, and with the network stack already registered',
      () async {
        stubFetchSuccess();
        ServerIdentity? seenIdentity;
        Dio? resolvedDuringInstall;

        scope = await bootstrap(
          installStorage: (container, identity) async {
            seenIdentity = identity;
            // The web installer derives its database name from the identity
            // and resolves per-server resources from this container, so both
            // must already be usable at this point.
            resolvedDuringInstall = container.get<Dio>();
          },
        );

        expect(seenIdentity, _identity());
        expect(resolvedDuringInstall, isNotNull);
        expect(scope!.active!.container.get<Dio>(), resolvedDuringInstall);
      },
    );

    test('can register into the scope the caller then receives', () async {
      stubFetchSuccess();

      scope = await bootstrap(
        installStorage: (container, identity) async =>
            container.registerSingleton<_FakeDatabase>(const _FakeDatabase()),
      );

      expect(scope!.active!.container.get<_FakeDatabase>(), isNotNull);
    });

    test('a storage failure propagates, and disposes what the network '
        'registration had already put in the container', () async {
      stubFetchSuccess();
      var disposed = false;

      await expectLater(
        bootstrap(
          installStorage: (container, identity) async {
            // Stands in for a resource registered before the failure — the
            // real leak this guard exists for is the Dio and the clock.
            container.registerSingleton<_FakeDatabase>(
              const _FakeDatabase(),
              dispose: (_) => disposed = true,
            );
            throw StateError('no storage for you');
          },
        ),
        throwsStateError,
      );

      expect(
        disposed,
        isTrue,
        reason:
            'the caller discards the scope on a failed bootstrap, so the '
            'partial container has to be disposed here or it leaks',
      );
      // Nothing was returned, so tearDown has nothing to dispose.
      expect(scope, isNull);
    });
  });
}

/// Stands in for the `ServerDatabase` the real seam registers; this package
/// cannot see that type, which is the entire point of the seam.
class _FakeDatabase {
  const _FakeDatabase();
}
