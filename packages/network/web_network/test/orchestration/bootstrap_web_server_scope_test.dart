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

  Future<ActiveServerScope> bootstrap() => bootstrapWebServerScope(
    wellKnownClient: wellKnownClient,
    // Uri.base has no origin on the VM, so the origin is injected; production
    // defaults to WebDioFactory.currentOrigin (the browser address bar).
    originProvider: () => _kOrigin,
  );

  void stubFetchSuccess() => when(
    () => wellKnownClient.fetchIdentity(any()),
  ).thenAnswer((_) async => _identity());

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
}
