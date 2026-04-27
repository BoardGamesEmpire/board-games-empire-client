import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

// Canonical fixture matching the /.well-known/bge-identity wire format.
// Keys are snake_case per SnakeCaseInterceptor on the NestJS backend.
Map<String, dynamic> _fullIdentityJson({
  String serverId = '550e8400-e29b-41d4-a716-446655440000',
  String issuer = 'https://api.example.com',
  bool passkeySupported = true,
  bool twoFactorSupported = true,
  bool anonymousAuthSupported = true,
  List<Map<String, dynamic>>? strategies,
}) => {
  'bge_server_id': serverId,
  'issuer': issuer,
  'device_authorization_endpoint': 'https://api.example.com/api/auth/device',
  'bge_auth_base_url': 'https://api.example.com/api/auth',
  'bge_session_endpoint': 'https://api.example.com/api/auth/get-session',
  'bge_sign_out_endpoint': 'https://api.example.com/api/auth/sign-out',
  'bge_passkey_supported': passkeySupported,
  'bge_two_factor_supported': twoFactorSupported,
  'bge_anonymous_auth_supported': anonymousAuthSupported,
  'strategies': strategies ?? [],
};

void main() {
  group('ServerIdentity', () {
    group('fromJson', () {
      test('deserializes all required fields from snake_case wire format', () {
        final identity = ServerIdentity.fromJson(_fullIdentityJson());

        expect(identity.serverId, '550e8400-e29b-41d4-a716-446655440000');
        expect(identity.issuer, 'https://api.example.com');
        expect(
          identity.deviceAuthorizationEndpoint,
          'https://api.example.com/api/auth/device',
        );
        expect(identity.authBaseUrl, 'https://api.example.com/api/auth');
        expect(
          identity.sessionEndpoint,
          'https://api.example.com/api/auth/get-session',
        );
        expect(
          identity.signOutEndpoint,
          'https://api.example.com/api/auth/sign-out',
        );
        expect(identity.passkeySupported, isTrue);
        expect(identity.twoFactorSupported, isTrue);
        expect(identity.anonymousAuthSupported, isTrue);
      });

      test('deserializes empty strategies list', () {
        final identity = ServerIdentity.fromJson(_fullIdentityJson());
        expect(identity.strategies, isEmpty);
      });

      test('deserializes mixed strategies list', () {
        final json = _fullIdentityJson(
          strategies: [
            {
              'type': 'email_and_password',
              'sign_up_disabled': false,
              'sign_in_endpoint':
                  'https://api.example.com/api/auth/sign-in/email',
              'sign_up_endpoint':
                  'https://api.example.com/api/auth/sign-up/email',
            },
            {
              'type': 'oidc',
              'provider_id': 'acme-sso',
              'discovery_url':
                  'https://auth.acme.com/.well-known/openid-configuration',
              'authorization_endpoint':
                  'https://api.example.com/api/auth/sign-in/oauth2',
            },
          ],
        );

        final identity = ServerIdentity.fromJson(json);

        expect(identity.strategies, hasLength(2));
        expect(identity.strategies[0], isA<EmailAndPasswordStrategy>());
        expect(identity.strategies[1], isA<OidcStrategy>());
      });

      test('strategies defaults to empty list when key is absent', () {
        final json = Map<String, dynamic>.from(_fullIdentityJson())
          ..remove('strategies');

        final identity = ServerIdentity.fromJson(json);

        expect(identity.strategies, isEmpty);
      });

      test('preserves false capability flags', () {
        final json = _fullIdentityJson(
          passkeySupported: false,
          twoFactorSupported: false,
          anonymousAuthSupported: false,
        );

        final identity = ServerIdentity.fromJson(json);

        expect(identity.passkeySupported, isFalse);
        expect(identity.twoFactorSupported, isFalse);
        expect(identity.anonymousAuthSupported, isFalse);
      });
    });

    group('toJson', () {
      test('serializes back to snake_case wire format', () {
        final identity = ServerIdentity.fromJson(_fullIdentityJson());
        final json = identity.toJson();

        expect(json['bge_server_id'], '550e8400-e29b-41d4-a716-446655440000');
        expect(json['issuer'], 'https://api.example.com');
        expect(
          json['device_authorization_endpoint'],
          'https://api.example.com/api/auth/device',
        );
        expect(json['bge_auth_base_url'], 'https://api.example.com/api/auth');
        expect(
          json['bge_session_endpoint'],
          'https://api.example.com/api/auth/get-session',
        );
        expect(
          json['bge_sign_out_endpoint'],
          'https://api.example.com/api/auth/sign-out',
        );
        expect(json['bge_passkey_supported'], isTrue);
        expect(json['bge_two_factor_supported'], isTrue);
        expect(json['bge_anonymous_auth_supported'], isTrue);
      });

      test('round-trips fromJson → toJson → fromJson with strategies', () {
        final originalJson = _fullIdentityJson(
          strategies: [
            {
              'type': 'email_and_password',
              'sign_up_disabled': true,
              'sign_in_endpoint':
                  'https://api.example.com/api/auth/sign-in/email',
            },
          ],
        );

        final first = ServerIdentity.fromJson(originalJson);
        final second = ServerIdentity.fromJson(first.toJson());

        expect(second.serverId, first.serverId);
        expect(second.strategies, hasLength(1));
        expect(second.strategies[0], isA<EmailAndPasswordStrategy>());

        final ep = second.strategies[0] as EmailAndPasswordStrategy;
        expect(ep.signUpDisabled, isTrue);
        expect(ep.signUpEndpoint, isNull);
      });
    });

    group('copyWith', () {
      test('produces updated identity without mutating original', () {
        final original = ServerIdentity.fromJson(_fullIdentityJson());
        final updated = original.copyWith(
          issuer: 'https://new.example.com',
          passkeySupported: false,
        );

        expect(original.issuer, 'https://api.example.com');
        expect(original.passkeySupported, isTrue);
        expect(updated.issuer, 'https://new.example.com');
        expect(updated.passkeySupported, isFalse);
        expect(updated.serverId, original.serverId);
      });
    });

    group('equality', () {
      test('two identities with identical fields are equal', () {
        final a = ServerIdentity.fromJson(_fullIdentityJson());
        final b = ServerIdentity.fromJson(_fullIdentityJson());

        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('identities with different serverIds are not equal', () {
        final a = ServerIdentity.fromJson(
          _fullIdentityJson(serverId: 'uuid-one'),
        );
        final b = ServerIdentity.fromJson(
          _fullIdentityJson(serverId: 'uuid-two'),
        );

        expect(a, isNot(equals(b)));
      });
    });

    group('helper accessors', () {
      test('hasEmailAndPassword returns true when strategy present', () {
        final json = _fullIdentityJson(
          strategies: [
            {
              'type': 'email_and_password',
              'sign_up_disabled': false,
              'sign_in_endpoint':
                  'https://api.example.com/api/auth/sign-in/email',
            },
          ],
        );
        final identity = ServerIdentity.fromJson(json);

        expect(identity.hasEmailAndPassword, isTrue);
        expect(identity.hasOidc, isFalse);
      });

      test('hasOidc returns true when OIDC strategy present', () {
        final json = _fullIdentityJson(
          strategies: [
            {
              'type': 'oidc',
              'provider_id': 'acme-sso',
              'discovery_url':
                  'https://auth.acme.com/.well-known/openid-configuration',
              'authorization_endpoint':
                  'https://api.example.com/api/auth/sign-in/oauth2',
            },
          ],
        );
        final identity = ServerIdentity.fromJson(json);

        expect(identity.hasOidc, isTrue);
        expect(identity.hasEmailAndPassword, isFalse);
      });

      test('returns false for both when strategies is empty', () {
        final identity = ServerIdentity.fromJson(_fullIdentityJson());

        expect(identity.hasEmailAndPassword, isFalse);
        expect(identity.hasOidc, isFalse);
      });
    });
  });
}
