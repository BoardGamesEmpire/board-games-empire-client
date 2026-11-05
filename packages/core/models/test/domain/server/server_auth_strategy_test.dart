import 'package:test/test.dart';
import 'package:models/domain.dart';

void main() {
  group('ServerAuthStrategy', () {
    group('fromJson', () {
      group('EmailAndPasswordStrategy', () {
        test('deserializes with registration open', () {
          final json = {
            'type': 'email_and_password',
            'sign_up_disabled': false,
            'sign_in_endpoint': '/api/auth/sign-in/email',
            'sign_up_endpoint': '/api/auth/sign-up/email',
          };

          final strategy = ServerAuthStrategy.fromJson(json);

          expect(strategy, isA<EmailAndPasswordStrategy>());
          final ep = strategy as EmailAndPasswordStrategy;
          expect(ep.signUpDisabled, isFalse);
          expect(ep.signInEndpoint, '/api/auth/sign-in/email');
          expect(ep.signUpEndpoint, '/api/auth/sign-up/email');
        });

        test(
          'deserializes with registration disabled — signUpEndpoint null',
          () {
            final json = {
              'type': 'email_and_password',
              'sign_up_disabled': true,
              'sign_in_endpoint': '/api/auth/sign-in/email',
            };

            final strategy = ServerAuthStrategy.fromJson(json);

            final ep = strategy as EmailAndPasswordStrategy;
            expect(ep.signUpDisabled, isTrue);
            expect(ep.signUpEndpoint, isNull);
          },
        );
      });

      group('OidcStrategy', () {
        test('parses the discovery shape the backend e2e test pins', () {
          final s = OidcStrategy.fromJson({
            'type': 'oidc',
            'provider_id': 'authentik',
            'display_name': 'Authentik',
            'discovery_url':
                'https://auth.example.com/.well-known/openid-configuration',
            'authorization_endpoint': '/api/auth/sign-in/social',
            'app_sign_in_endpoint': '/api/auth/app-sign-in/start',
            'app_token_endpoint': '/api/auth/app-sign-in/token',
            'sign_up_disabled': false,
          });

          expect(s.displayName, 'Authentik');
          expect(s.appSignInEndpoint, '/api/auth/app-sign-in/start');
          expect(s.appTokenEndpoint, '/api/auth/app-sign-in/token');
        });

        for (final key in [
          'display_name',
          'app_sign_in_endpoint',
          'app_token_endpoint',
        ]) {
          test('a strategy without $key fails to parse', () {
            final json = <String, dynamic>{
              'type': 'oidc',
              'provider_id': 'authentik',
              'display_name': 'Authentik',
              'discovery_url':
                  'https://auth.example.com/.well-known/openid-configuration',
              'authorization_endpoint': '/api/auth/sign-in/social',
              'app_sign_in_endpoint': '/api/auth/app-sign-in/start',
              'app_token_endpoint': '/api/auth/app-sign-in/token',
            }..remove(key);

            expect(
              () => OidcStrategy.fromJson(json),
              throwsA(isA<TypeError>()),
            );
          });
        }

        test('toJson round-trips the new keys', () {
          final json = {
            'type': 'oidc',
            'sign_up_disabled': false,
            'provider_id': 'authentik',
            'display_name': 'Authentik',
            'discovery_url':
                'https://auth.example.com/.well-known/openid-configuration',
            'authorization_endpoint': '/api/auth/sign-in/social',
            'app_sign_in_endpoint': '/api/auth/app-sign-in/start',
            'app_token_endpoint': '/api/auth/app-sign-in/token',
          };

          expect(OidcStrategy.fromJson(json).toJson(), json);
        });
        test('deserializes all fields', () {
          final json = {
            'type': 'oidc',
            'provider_id': 'acme-sso',
            'discovery_url':
                'https://auth.acme.com/.well-known/openid-configuration',
            'authorization_endpoint': '/api/auth/sign-in/oauth2',
            'display_name': 'Acme SSO',
            'app_sign_in_endpoint': '/api/auth/app-sign-in/start',
            'app_token_endpoint': '/api/auth/app-sign-in/token',
          };

          final strategy = ServerAuthStrategy.fromJson(json);

          expect(strategy, isA<OidcStrategy>());
          final oidc = strategy as OidcStrategy;
          expect(oidc.providerId, 'acme-sso');
          expect(
            oidc.discoveryUrl,
            'https://auth.acme.com/.well-known/openid-configuration',
          );
          expect(oidc.authorizationEndpoint, '/api/auth/sign-in/oauth2');
        });

        // A server older than backend#585 sends no such field, and failing
        // the whole discovery parse over one nothing reads yet would turn a
        // working server into an invalid response (#443).
        test('an OIDC strategy without sign_up_disabled parses as open', () {
          final json = {
            'type': 'oidc',
            'provider_id': 'acme-sso',
            'discovery_url':
                'https://auth.acme.com/.well-known/openid-configuration',
            'authorization_endpoint': '/api/auth/sign-in/oauth2',
            'display_name': 'Acme SSO',
            'app_sign_in_endpoint': '/api/auth/app-sign-in/start',
            'app_token_endpoint': '/api/auth/app-sign-in/token',
          };

          final oidc = ServerAuthStrategy.fromJson(json) as OidcStrategy;

          expect(oidc.signUpDisabled, isFalse);
        });

        test('an OIDC strategy reads sign_up_disabled', () {
          final json = {
            'type': 'oidc',
            'sign_up_disabled': true,
            'provider_id': 'acme-sso',
            'discovery_url':
                'https://auth.acme.com/.well-known/openid-configuration',
            'authorization_endpoint': '/api/auth/sign-in/oauth2',
            'display_name': 'Acme SSO',
            'app_sign_in_endpoint': '/api/auth/app-sign-in/start',
            'app_token_endpoint': '/api/auth/app-sign-in/token',
          };

          final oidc = ServerAuthStrategy.fromJson(json) as OidcStrategy;

          expect(oidc.signUpDisabled, isTrue);
          expect(oidc.toJson()['sign_up_disabled'], isTrue);
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
          signInEndpoint: '/api/auth/sign-in/email',
          signUpEndpoint: '/api/auth/sign-up/email',
        );

        final json = strategy.toJson();

        expect(json['type'], AuthStrategyType.emailAndPassword);
        expect(json['sign_up_disabled'], isFalse);
        expect(json['sign_in_endpoint'], '/api/auth/sign-in/email');
        expect(json['sign_up_endpoint'], '/api/auth/sign-up/email');
      });

      test('EmailAndPasswordStrategy omits sign_up_endpoint when null', () {
        const strategy = EmailAndPasswordStrategy(
          signUpDisabled: true,
          signInEndpoint: '/api/auth/sign-in/email',
        );

        final json = strategy.toJson();

        expect(json.containsKey('sign_up_endpoint'), isFalse);
      });

      test('OidcStrategy round-trips correctly', () {
        const strategy = OidcStrategy(
          providerId: 'acme-sso',
          discoveryUrl:
              'https://auth.acme.com/.well-known/openid-configuration',
          authorizationEndpoint: '/api/auth/sign-in/oauth2',
          displayName: 'Acme SSO',
          appSignInEndpoint: '/api/auth/app-sign-in/start',
          appTokenEndpoint: '/api/auth/app-sign-in/token',
        );

        final json = strategy.toJson();

        expect(json['type'], AuthStrategyType.oidc);
        expect(json['provider_id'], 'acme-sso');
        expect(
          json['discovery_url'],
          'https://auth.acme.com/.well-known/openid-configuration',
        );
        expect(json['authorization_endpoint'], '/api/auth/sign-in/oauth2');
      });
    });

    group('equality', () {
      test('two EmailAndPasswordStrategy with same fields are equal', () {
        const a = EmailAndPasswordStrategy(
          signUpDisabled: false,
          signInEndpoint: '/api/auth/sign-in/email',
          signUpEndpoint: '/api/auth/sign-up/email',
        );
        const b = EmailAndPasswordStrategy(
          signUpDisabled: false,
          signInEndpoint: '/api/auth/sign-in/email',
          signUpEndpoint: '/api/auth/sign-up/email',
        );

        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test(
        'EmailAndPasswordStrategy with different signUpDisabled are not equal',
        () {
          const a = EmailAndPasswordStrategy(
            signUpDisabled: false,
            signInEndpoint: '/api/auth/sign-in/email',
          );
          const b = EmailAndPasswordStrategy(
            signUpDisabled: true,
            signInEndpoint: '/api/auth/sign-in/email',
          );

          expect(a, isNot(equals(b)));
        },
      );

      test('two OidcStrategy with same fields are equal', () {
        const a = OidcStrategy(
          providerId: 'acme',
          discoveryUrl:
              'https://auth.acme.com/.well-known/openid-configuration',
          authorizationEndpoint: '/api/auth/sign-in/oauth2',
          displayName: 'Acme SSO',
          appSignInEndpoint: '/api/auth/app-sign-in/start',
          appTokenEndpoint: '/api/auth/app-sign-in/token',
        );
        const b = OidcStrategy(
          providerId: 'acme',
          discoveryUrl:
              'https://auth.acme.com/.well-known/openid-configuration',
          authorizationEndpoint: '/api/auth/sign-in/oauth2',
          displayName: 'Acme SSO',
          appSignInEndpoint: '/api/auth/app-sign-in/start',
          appTokenEndpoint: '/api/auth/app-sign-in/token',
        );

        expect(a, equals(b));
      });

      test('sign_up_disabled is part of OIDC equality', () {
        const open = OidcStrategy(
          providerId: 'acme',
          discoveryUrl:
              'https://auth.acme.com/.well-known/openid-configuration',
          authorizationEndpoint: '/api/auth/sign-in/oauth2',
          displayName: 'Acme SSO',
          appSignInEndpoint: '/api/auth/app-sign-in/start',
          appTokenEndpoint: '/api/auth/app-sign-in/token',
        );
        const closed = OidcStrategy(
          signUpDisabled: true,
          providerId: 'acme',
          discoveryUrl:
              'https://auth.acme.com/.well-known/openid-configuration',
          authorizationEndpoint: '/api/auth/sign-in/oauth2',
          displayName: 'Acme SSO',
          appSignInEndpoint: '/api/auth/app-sign-in/start',
          appTokenEndpoint: '/api/auth/app-sign-in/token',
        );

        expect(open, isNot(equals(closed)));
      });

      // Each field #583 added: one that drops out of `props` fails here.
      OidcStrategy acme({
        String displayName = 'Acme SSO',
        String appSignInEndpoint = '/api/auth/app-sign-in/start',
        String appTokenEndpoint = '/api/auth/app-sign-in/token',
      }) => OidcStrategy(
        providerId: 'acme',
        discoveryUrl: 'https://auth.acme.com/.well-known/openid-configuration',
        authorizationEndpoint: '/api/auth/sign-in/oauth2',
        displayName: displayName,
        appSignInEndpoint: appSignInEndpoint,
        appTokenEndpoint: appTokenEndpoint,
      );

      for (final (field, other) in [
        ('display_name', acme(displayName: 'Other SSO')),
        ('app_sign_in_endpoint', acme(appSignInEndpoint: '/other/start')),
        ('app_token_endpoint', acme(appTokenEndpoint: '/other/token')),
      ]) {
        test('$field is part of OIDC equality', () {
          expect(acme(), equals(acme()));
          expect(acme(), isNot(equals(other)));
        });
      }
    });

    group('switch exhaustiveness', () {
      test('sealed variants are exhaustively matchable', () {
        final List<ServerAuthStrategy> strategies = [
          const EmailAndPasswordStrategy(
            signUpDisabled: false,
            signInEndpoint: '/api/auth/sign-in/email',
          ),
          const OidcStrategy(
            providerId: 'test',
            discoveryUrl:
                'https://auth.test.com/.well-known/openid-configuration',
            authorizationEndpoint: '/api/auth/sign-in/oauth2',
            displayName: 'Acme SSO',
            appSignInEndpoint: '/api/auth/app-sign-in/start',
            appTokenEndpoint: '/api/auth/app-sign-in/token',
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
            'sign_in_endpoint': '/api/auth/sign-in/email',
            'sign_up_endpoint': '/api/auth/sign-up/email',
          },
          {
            'type': 'oidc',
            'provider_id': 'acme-sso',
            'discovery_url':
                'https://auth.acme.com/.well-known/openid-configuration',
            'authorization_endpoint': '/api/auth/sign-in/oauth2',
            'display_name': 'Acme SSO',
            'app_sign_in_endpoint': '/api/auth/app-sign-in/start',
            'app_token_endpoint': '/api/auth/app-sign-in/token',
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
            signInEndpoint: '/api/auth/sign-in/email',
          ),
        ];

        final raw = converter.toJson(strategies);
        final restored = converter.fromJson(raw);

        expect(restored, equals(strategies));
      });
    });
  });
}
