import 'package:di/di.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/services.dart';
import 'package:models/domain.dart';

BuildInfo _buildInfo(String version) => BuildInfo(
  version: version,
  buildNumber: '1',
  appName: 'BGE',
  packageName: 'com.bge.app',
);

ServerIdentity _identity({
  int schemaVersion = 1,
  String? minClientVersion,
  String? maxClientVersion,
}) => ServerIdentity(
  wellKnownSchemaVersion: schemaVersion,
  serverId: '550e8400-e29b-41d4-a716-446655440000',
  name: 'Test BGE Server',
  minClientVersion: minClientVersion,
  maxClientVersion: maxClientVersion,
  issuer: 'https://api.example.com',
  deviceAuthorizationEndpoint: '/api/auth/device',
  authBasePath: '/api/auth',
  sessionEndpoint: '/api/auth/get-session',
  signOutEndpoint: '/api/auth/sign-out',
  passkeySupported: true,
  twoFactorSupported: true,
  anonymousAuthSupported: true,
);

void main() {
  const negotiator = VersionNegotiatorImpl();

  group('VersionNegotiatorImpl.negotiate', () {
    group('open bounds', () {
      test('compatible when both bounds are null', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('1.2.3'),
          identity: _identity(),
        );

        expect(result, const VersionCompatible());
      });
    });

    group('minimum bound', () {
      test('compatible when client is above the minimum', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('1.2.3'),
          identity: _identity(minClientVersion: '1.0.0'),
        );

        expect(result, const VersionCompatible());
      });

      test('compatible when client equals the minimum (inclusive)', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('1.0.0'),
          identity: _identity(minClientVersion: '1.0.0'),
        );

        expect(result, const VersionCompatible());
      });

      test('clientTooOld when client is below the minimum', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('0.9.0'),
          identity: _identity(minClientVersion: '1.0.0'),
        );

        expect(
          result,
          const ClientTooOld(clientVersion: '0.9.0', requiredMinimum: '1.0.0'),
        );
      });

      test('pre-release client is older than the release minimum', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('1.0.0-beta.1'),
          identity: _identity(minClientVersion: '1.0.0'),
        );

        expect(result, isA<ClientTooOld>());
      });
    });

    group('maximum bound', () {
      test('compatible when client is below the maximum', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('1.5.0'),
          identity: _identity(maxClientVersion: '2.0.0'),
        );

        expect(result, const VersionCompatible());
      });

      test('compatible when client equals the maximum (inclusive)', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('2.0.0'),
          identity: _identity(maxClientVersion: '2.0.0'),
        );

        expect(result, const VersionCompatible());
      });

      test('clientTooNew when client is above the maximum', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('2.1.0'),
          identity: _identity(maxClientVersion: '2.0.0'),
        );

        expect(
          result,
          const ClientTooNew(clientVersion: '2.1.0', supportedMaximum: '2.0.0'),
        );
      });
    });

    group('both bounds', () {
      test('compatible when client sits inside the window', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('1.5.0'),
          identity: _identity(
            minClientVersion: '1.0.0',
            maxClientVersion: '2.0.0',
          ),
        );

        expect(result, const VersionCompatible());
      });

      test('minimum is evaluated before maximum', () {
        // A window that excludes everything: below-min reports tooOld,
        // not tooNew, because the minimum check runs first.
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('0.5.0'),
          identity: _identity(
            minClientVersion: '1.0.0',
            maxClientVersion: '0.9.0',
          ),
        );

        expect(result, isA<ClientTooOld>());
      });
    });

    group('schema version', () {
      test('schemaTooNew when the document schema is newer', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('1.2.3'),
          identity: _identity(schemaVersion: 2),
        );

        expect(
          result,
          const SchemaTooNew(
            serverSchemaVersion: 2,
            supportedSchemaVersion: kSupportedWellKnownSchemaVersion,
          ),
        );
      });

      test('schema check takes precedence over version bounds', () {
        // With a too-new schema the version fields may not mean what
        // this client thinks; refuse on schema even though the client
        // also violates the minimum.
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('0.1.0'),
          identity: _identity(schemaVersion: 99, minClientVersion: '1.0.0'),
        );

        expect(result, isA<SchemaTooNew>());
      });

      test('the supported schema version itself is compatible', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('1.2.3'),
          identity: _identity(schemaVersion: kSupportedWellKnownSchemaVersion),
        );

        expect(result, const VersionCompatible());
      });
    });

    group('failure policy — client side (fail closed)', () {
      test('BuildInfo.unknown fails a server-declared minimum', () {
        // BuildInfo.unknown carries 0.0.0 by design: an unreadable client
        // version must be treated as "needs update", not waved through.
        final result = negotiator.negotiate(
          buildInfo: BuildInfo.unknown,
          identity: _identity(minClientVersion: '0.1.0'),
        );

        expect(
          result,
          const ClientTooOld(clientVersion: '0.0.0', requiredMinimum: '0.1.0'),
        );
      });

      test('unparseable client version degrades to oldest and fails '
          'a minimum', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('not-a-version'),
          identity: _identity(minClientVersion: '0.1.0'),
        );

        expect(result, isA<ClientTooOld>());
      });

      test('reports the verbatim client version, not the 0.0.0 comparison '
          'sentinel, when the version is unparseable', () {
        // The 0.0.0 fallback is a comparison-only mechanism; the payload
        // must surface the real (broken) version string for diagnostics.
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('not-a-version'),
          identity: _identity(minClientVersion: '0.1.0'),
        );

        expect(
          result,
          const ClientTooOld(
            clientVersion: 'not-a-version',
            requiredMinimum: '0.1.0',
          ),
        );
      });

      test('unparseable client version is compatible with open bounds', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('not-a-version'),
          identity: _identity(),
        );

        expect(result, const VersionCompatible());
      });
    });

    group('failure policy — server side (fail open)', () {
      test('malformed minimum bound is ignored', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('1.0.0'),
          identity: _identity(minClientVersion: 'banana'),
        );

        expect(result, const VersionCompatible());
      });

      test('malformed maximum bound is ignored', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('1.0.0'),
          identity: _identity(maxClientVersion: 'banana'),
        );

        expect(result, const VersionCompatible());
      });

      test('a malformed bound does not mask the other, valid bound', () {
        final result = negotiator.negotiate(
          buildInfo: _buildInfo('3.0.0'),
          identity: _identity(
            minClientVersion: 'banana',
            maxClientVersion: '2.0.0',
          ),
        );

        expect(result, isA<ClientTooNew>());
      });
    });
  });
}
