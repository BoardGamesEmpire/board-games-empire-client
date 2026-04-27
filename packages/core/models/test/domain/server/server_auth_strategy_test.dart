import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

void main() {
  group('ServerAuthStrategy', () {
    group('fromJson', () {
      group('EmailAndPasswordStrategy', () {
        test('deserializes with registration open', () {
          final json = {
            'type': 'email_and_password',
            'sign_up_disabled': false,
            'sign_in_endpoint':
                'https://api.example.com/api/auth/sign-in/email',
            'sign_up_endpoint':
                'https://api.example.com/api/auth/sign-up/email',
          };

          final strategy = ServerAuthStrategy.fromJson(json);

          expect(strategy, isA<EmailAndPasswordStrategy>());
          final ep = strategy as EmailAndPasswordStrategy;
          expect(ep.signUpDisabled, isFalse);
          expect(
            ep.signInEndpoint,
            'https://api.example.com/api/auth/sign-in/email',
          );
          expect(
            ep.signUpEndpoint,
            'https://api.example.com/api/auth/sign-up/email',
          );
        });

        test(
          'deserializes with registration disabled — signUpEndpoint null',
          () {
            final json = {
              'type': 'email_and_password',
              'sign_up_disabled': true,
              'sign_in_endpoint':
                  'https://api.example.com/api/auth/sign-in/email',
            };

            final strategy = ServerAuthStrategy.fromJson(json);

            final ep = strategy as EmailAndPasswordStrategy;
            expect(ep.signUpDisabled, isTrue);
            expect(ep.signUpEndpoint, isNull);
          },
        );
      });

      group('OidcStrategy', () {
        test('deserializes all fields', () {
          final json = {
            'type': 'oidc',
            'provider_id': 'acme-sso',
            'discovery_url':
                'https://auth.acme.com/.well-known/openid-configuration',
            'authorization_endpoint':
                'https://api.example.com/api/auth/sign-in/oauth2',
          };

          final strategy = ServerAuthStrategy.fromJson(json);

          expect(strategy, isA<OidcStrategy>());
          final oidc = strategy as OidcStrategy;
          expect(oidc.providerId, 'acme-sso');
          expect(
            oidc.discoveryUrl,
            'https://auth.acme.com/.well-known/openid-configuration',
          );
          expect(
            oidc.authorizationEndpoint,
            'https://api.example.com/api/auth/sign-in/oauth2',
          );
        });
      });

      test('throws FormatException for unknown type', () {
        final json = {'type': 'ldap', 'server': 'ldap://internal.example.com'};

        expect(
          () => ServerAuthStrategy.fromJson(json),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('ldap'),
            ),
          ),
        );
      });

      test('throws FormatException when type field is null', () {
        final json = <String, dynamic>{'sign_in_endpoint': 'https://x.com'};

        expect(
          () => ServerAuthStrategy.fromJson(json),
          throwsA(isA<FormatException>()),
        );
      });
    });

    group('toJson', () {
      test('EmailAndPasswordStrategy round-trips with sign-up open', () {
        const strategy = EmailAndPasswordStrategy(
          signUpDisabled: false,
          signInEndpoint: 'https://api.example.com/api/auth/sign-in/email',
          signUpEndpoint: 'https://api.example.com/api/auth/sign-up/email',
        );

        final json = strategy.toJson();

        expect(json['type'], AuthStrategyType.emailAndPassword);
        expect(json['sign_up_disabled'], isFalse);
        expect(
          json['sign_in_endpoint'],
          'https://api.example.com/api/auth/sign-in/email',
        );
        expect(
          json['sign_up_endpoint'],
          'https://api.example.com/api/auth/sign-up/email',
        );
      });

      test('EmailAndPasswordStrategy omits sign_up_endpoint when null', () {
        const strategy = EmailAndPasswordStrategy(
          signUpDisabled: true,
          signInEndpoint: 'https://api.example.com/api/auth/sign-in/email',
        );

        final json = strategy.toJson();

        expect(json.containsKey('sign_up_endpoint'), isFalse);
      });

      test('OidcStrategy round-trips correctly', () {
        const strategy = OidcStrategy(
          providerId: 'acme-sso',
          discoveryUrl:
              'https://auth.acme.com/.well-known/openid-configuration',
          authorizationEndpoint:
              'https://api.example.com/api/auth/sign-in/oauth2',
        );

        final json = strategy.toJson();

        expect(json['type'], AuthStrategyType.oidc);
        expect(json['provider_id'], 'acme-sso');
        expect(
          json['discovery_url'],
          'https://auth.acme.com/.well-known/openid-configuration',
        );
        expect(
          json['authorization_endpoint'],
          'https://api.example.com/api/auth/sign-in/oauth2',
        );
      });
    });

    group('equality', () {
      test('two EmailAndPasswordStrategy with same fields are equal', () {
        const a = EmailAndPasswordStrategy(
          signUpDisabled: false,
          signInEndpoint: 'https://api.example.com/api/auth/sign-in/email',
          signUpEndpoint: 'https://api.example.com/api/auth/sign-up/email',
        );
        const b = EmailAndPasswordStrategy(
          signUpDisabled: false,
          signInEndpoint: 'https://api.example.com/api/auth/sign-in/email',
          signUpEndpoint: 'https://api.example.com/api/auth/sign-up/email',
        );

        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test(
        'EmailAndPasswordStrategy with different signUpDisabled are not equal',
        () {
          const a = EmailAndPasswordStrategy(
            signUpDisabled: false,
            signInEndpoint: 'https://api.example.com/api/auth/sign-in/email',
          );
          const b = EmailAndPasswordStrategy(
            signUpDisabled: true,
            signInEndpoint: 'https://api.example.com/api/auth/sign-in/email',
          );

          expect(a, isNot(equals(b)));
        },
      );

      test('two OidcStrategy with same fields are equal', () {
        const a = OidcStrategy(
          providerId: 'acme',
          discoveryUrl:
              'https://auth.acme.com/.well-known/openid-configuration',
          authorizationEndpoint:
              'https://api.example.com/api/auth/sign-in/oauth2',
        );
        const b = OidcStrategy(
          providerId: 'acme',
          discoveryUrl:
              'https://auth.acme.com/.well-known/openid-configuration',
          authorizationEndpoint:
              'https://api.example.com/api/auth/sign-in/oauth2',
        );

        expect(a, equals(b));
      });
    });

    group('switch exhaustiveness', () {
      test('sealed variants are exhaustively matchable', () {
        final List<ServerAuthStrategy> strategies = [
          const EmailAndPasswordStrategy(
            signUpDisabled: false,
            signInEndpoint: 'https://api.example.com/api/auth/sign-in/email',
          ),
          const OidcStrategy(
            providerId: 'test',
            discoveryUrl:
                'https://auth.test.com/.well-known/openid-configuration',
            authorizationEndpoint:
                'https://api.example.com/api/auth/sign-in/oauth2',
          ),
        ];

        final labels = strategies.map(
          (s) => switch (s) {
            EmailAndPasswordStrategy() => 'email',
            OidcStrategy() => 'oidc',
          },
        );

        expect(labels, containsAllInOrder(['email', 'oidc']));
      });
    });

    group('ServerAuthStrategyListConverter', () {
      const converter = ServerAuthStrategyListConverter();

      test('fromJson deserializes a mixed strategy list', () {
        final raw = [
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
        ];

        final strategies = converter.fromJson(raw);

        expect(strategies, hasLength(2));
        expect(strategies[0], isA<EmailAndPasswordStrategy>());
        expect(strategies[1], isA<OidcStrategy>());
      });

      test('fromJson handles empty list', () {
        expect(converter.fromJson([]), isEmpty);
      });

      test('toJson round-trips back to deserializable form', () {
        const strategies = [
          EmailAndPasswordStrategy(
            signUpDisabled: false,
            signInEndpoint: 'https://api.example.com/api/auth/sign-in/email',
          ),
        ];

        final raw = converter.toJson(strategies);
        final restored = converter.fromJson(raw);

        expect(restored, equals(strategies));
      });
    });
  });
}
