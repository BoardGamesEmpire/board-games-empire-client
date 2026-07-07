import 'package:di/di.dart';
import 'package:dio/dio.dart';
import 'package:dio_network/dio_network.dart'
    show DioFactory, TokenStorageService;
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

import 'package:web_network/src/auth/web_auth_repository_impl.dart';
import 'package:web_network/src/network/register_server_network_web.dart';
import 'package:web_network/src/network/web_dio_factory.dart';

const _kAuthBase = '/api/auth';

// Web has no MetaDB and no persisted ServerConfig: the identity is fetched
// from the serving origin's well-known document at runtime. The registration
// helper therefore takes a ServerIdentity directly — constructing a synthetic
// ServerConfig just to carry one is the wart this signature removes.
ServerIdentity _identity() => ServerIdentity(
  serverId: 'server-uuid-1',
  issuer: 'https://bge.example.com',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBaseUrl: _kAuthBase,
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
  late DependencyContainerImpl container;

  setUp(() {
    container = DependencyContainerImpl();
  });

  tearDown(() async {
    await container.dispose();
  });

  void register({String origin = 'https://bge.example.com'}) =>
      registerServerNetworkWeb(
        container: container,
        identity: _identity(),
        // Uri.base has no origin on the VM, so tests inject one; production
        // defaults to WebDioFactory.currentOrigin (the address bar).
        originProvider: () => origin,
      );

  group('registerServerNetworkWeb', () {
    test('registers WebDioFactory as the DioFactory', () {
      register();

      expect(container.get<DioFactory>(), isA<WebDioFactory>());
    });

    test('registers a shared Dio whose baseUrl comes from the origin '
        'provider, normalized without a trailing slash', () {
      register(origin: 'https://bge.example.com/');

      final dio = container.get<Dio>();
      expect(dio.options.baseUrl, 'https://bge.example.com');
    });

    test('registers WebAuthRepositoryImpl as the AuthRepository', () {
      register();

      expect(container.get<AuthRepository>(), isA<WebAuthRepositoryImpl>());
    });

    test('registers no TokenStorageService — the browser owns the session '
        'cookie', () {
      register();

      expect(container.isRegistered<TokenStorageService>(), isFalse);
    });
  });
}
