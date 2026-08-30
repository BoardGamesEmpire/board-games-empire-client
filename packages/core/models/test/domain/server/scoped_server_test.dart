import 'package:models/domain.dart';
import 'package:test/test.dart';

const _kAuthBase = 'https://api.example.test/api/auth';

ServerIdentity _identity() => const ServerIdentity(
  serverId: 'bge-uuid-1',
  issuer: 'https://api.example.test',
  wellKnownSchemaVersion: 1,
  name: 'Advertised Name',
  deviceAuthorizationEndpoint: '$_kAuthBase/device',
  authBasePath: _kAuthBase,
  sessionEndpoint: '$_kAuthBase/get-session',
  signOutEndpoint: '$_kAuthBase/sign-out',
  passkeySupported: false,
  twoFactorSupported: false,
  anonymousAuthSupported: false,
  strategies: [
    EmailAndPasswordStrategy(
      signUpDisabled: false,
      signInEndpoint: '$_kAuthBase/sign-in/email',
      signUpEndpoint: '$_kAuthBase/sign-up/email',
    ),
  ],
);

ServerConfig _config() => ServerConfig(
  id: 'local-cuid-1',
  displayName: 'Local Alias',
  serverUrl: 'https://api.example.test',
  connectionState: ConnectionState.active,
  bgeServerId: 'bge-uuid-1',
  cachedIdentity: _identity(),
  lastIdentityFetchedAt: DateTime.utc(2026, 8, 29),
);

void main() {
  group('ScopedServer', () {
    test('fromConfig takes the server-vended id, not the local one', () {
      final config = _config();

      final server = ScopedServer.fromConfig(config);

      // The distinction the type exists to hold: `id` is a client-generated
      // cuid and a DB primary key; `bgeServerId` is what the server calls
      // itself, and is the only one web can also produce.
      expect(server.serverId, config.bgeServerId);
      expect(server.serverId, isNot(config.id));
    });

    test('fromConfig takes the local alias as the display name', () {
      // Native has a server-add flow, so the name a human recognises is the
      // one they chose — not the name the server advertises for itself.
      final config = _config();

      final server = ScopedServer.fromConfig(config);

      expect(server.displayName, 'Local Alias');
      expect(server.displayName, isNot(config.cachedIdentity.name));
    });

    test('fromIdentity takes the advertised name; web has no alias', () {
      final server = ScopedServer.fromIdentity(_identity());

      expect(server.serverId, 'bge-uuid-1');
      expect(server.displayName, 'Advertised Name');
    });

    test('both legs agree on the id for the same server', () {
      // The property that makes a diagnostic comparable across platforms.
      expect(
        ScopedServer.fromConfig(_config()).serverId,
        ScopedServer.fromIdentity(_identity()).serverId,
      );
    });

    test('is a value', () {
      const a = ScopedServer(serverId: 'a', displayName: 'A');
      const b = ScopedServer(serverId: 'a', displayName: 'A');
      const c = ScopedServer(serverId: 'a', displayName: 'B');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });
}
