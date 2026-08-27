import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';

const _kAuthBase = 'https://api.example.test/api/auth';

ServerConfig _config() => ServerConfig(
  id: 'local-1',
  displayName: 'My Server',
  serverUrl: 'https://api.example.test',
  connectionState: ConnectionState.active,
  bgeServerId: 'server-1',
  cachedIdentity: ServerIdentity(
    serverId: 'server-1',
    issuer: 'https://api.example.test',
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
  ),
  lastIdentityFetchedAt: DateTime.utc(2024),
);

void main() {
  late DependencyContainerImpl container;

  setUp(() => container = DependencyContainerImpl());

  test('install registers a SessionRehydrator for the session', () async {
    await const SessionRehydratorInstaller().install(
      container,
      _config(),
      'user-1',
    );

    expect(container.isRegistered<SessionRehydrator>(), isTrue);
  });

  test('the registered rehydrator runs a registered hydrate', () async {
    await const SessionRehydratorInstaller().install(
      container,
      _config(),
      'user-1',
    );

    var runs = 0;
    container.get<SessionRehydrator>().register(
      'household',
      isStale: () => true,
      run: () async => runs++,
    );
    await container.get<SessionRehydrator>().rehydrateStale();

    expect(runs, equals(1));
  });

  test('the session scope closes it, so a trigger arriving after sign-out '
      'runs nothing', () async {
    await const SessionRehydratorInstaller().install(
      container,
      _config(),
      'user-1',
    );
    final rehydrator = container.get<SessionRehydrator>();
    var runs = 0;
    rehydrator.register(
      'household',
      isStale: () => true,
      run: () async => runs++,
    );

    // What the user-session scope teardown does on sign-out.
    await container.dispose();
    await rehydrator.rehydrateStale();

    expect(runs, isZero);
  });
}
