import 'package:auth/src/sign_in_methods/sign_in_method_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart';

OidcStrategy _strategy(String id, [String? name]) => OidcStrategy(
  providerId: id,
  displayName: name ?? id,
  discoveryUrl: 'https://example.test/$id/.well-known',
  authorizationEndpoint: '/auth/$id',
  appSignInEndpoint: '/app/$id',
  appTokenEndpoint: '/token/$id',
);

SignInMethod _method(String id, String providerId) =>
    SignInMethod(id: id, providerId: providerId);

SignInMethod _password([String id = 'pw']) =>
    _method(id, SignInMethod.passwordProviderId);

/// [describeSignInMethods] on a server that offers email and password sign-in
/// unless [passwordSignInOffered] says otherwise.
({List<SignInMethodRow> rows, List<OidcStrategy> linkable}) _describe(
  List<SignInMethod> methods,
  List<OidcStrategy> strategies, {
  bool passwordSignInOffered = true,
}) => describeSignInMethods(
  methods,
  strategies,
  passwordSignInOffered: passwordSignInOffered,
);

final OidcStrategy _keycloak = _strategy('keycloak', 'Keycloak');
final OidcStrategy _github = _strategy('github', 'GitHub');

void main() {
  group('describeSignInMethods', () {
    test('a password plus one provider: the provider can unlink', () {
      final result = _describe(
        [_password(), _method('a', 'keycloak')],
        [_keycloak],
      );

      final provider = result.rows[1];
      expect(provider.isWayIn, isTrue);
      expect(provider.canUnlink, isTrue);
      expect(provider.unlinkIsLastWayIn, isFalse);
    });

    test('one provider alone: Unlink is withheld as the last way in', () {
      final result = _describe(
        [_method('a', 'keycloak')],
        [_keycloak],
      );

      expect(result.rows.single.canUnlink, isFalse);
      expect(result.rows.single.unlinkIsLastWayIn, isTrue);
    });

    test('two providers: both can unlink', () {
      final result = _describe(
        [_method('a', 'keycloak'), _method('b', 'github')],
        [_keycloak, _github],
      );

      expect(result.rows.map((r) => r.canUnlink), [true, true]);
      expect(result.rows.map((r) => r.unlinkIsLastWayIn), [false, false]);
    });

    test('a provider plus a removed one: the provider is withheld, the '
        'removed one can unlink', () {
      final result = _describe(
        [_method('gone', 'retired'), _method('a', 'keycloak')],
        [_keycloak],
      );

      final provider = result.rows[0];
      final removed = result.rows[1];
      expect(provider.label, isA<ProviderLabel>());
      expect(provider.canUnlink, isFalse);
      expect(provider.unlinkIsLastWayIn, isTrue);
      expect(removed.label, isA<RemovedProviderLabel>());
      expect(removed.isWayIn, isFalse);
      expect(removed.canUnlink, isTrue);
      expect(removed.unlinkIsLastWayIn, isFalse);
    });

    test('a removed provider alone is withheld', () {
      final result = _describe(
        [_method('gone', 'retired')],
        [_keycloak],
      );

      final row = result.rows.single;
      expect(row.isWayIn, isFalse);
      expect(row.canUnlink, isFalse);
      expect(row.unlinkIsLastWayIn, isTrue);
    });

    test('two rows for one provider: both listed and unlinkable, and the '
        'provider is not linkable', () {
      final result = _describe(
        [_method('a', 'keycloak'), _method('b', 'keycloak')],
        [_keycloak, _github],
      );

      expect(result.rows, hasLength(2));
      expect(result.rows.map((r) => r.canUnlink), [true, true]);
      expect(result.linkable, [_github]);
    });

    test('the password row never offers Unlink', () {
      final result = _describe(
        [_password(), _method('a', 'keycloak')],
        [_keycloak],
      );

      final row = result.rows.first;
      expect(row.label, isA<PasswordLabel>());
      expect(row.isWayIn, isTrue);
      expect(row.canUnlink, isFalse);
      expect(row.unlinkIsLastWayIn, isFalse);
    });

    test('a password the server no longer offers is no way in: the last '
        'provider is withheld', () {
      final result = _describe(
        [_password(), _method('a', 'keycloak')],
        [_keycloak],
        passwordSignInOffered: false,
      );

      final password = result.rows[0];
      final provider = result.rows[1];
      expect(password.label, isA<PasswordLabel>());
      expect(password.isWayIn, isFalse);
      expect(password.canUnlink, isFalse);
      expect(password.unlinkIsLastWayIn, isFalse);
      expect(provider.canUnlink, isFalse);
      expect(provider.unlinkIsLastWayIn, isTrue);
    });

    test('a password the server no longer offers, with two providers: both '
        'can unlink', () {
      final result = _describe(
        [_password(), _method('a', 'keycloak'), _method('b', 'github')],
        [_keycloak, _github],
        passwordSignInOffered: false,
      );

      expect(result.rows.map((r) => r.canUnlink), [false, true, true]);
    });

    test('a provider row carries the discovery display name', () {
      final result = _describe(
        [_method('a', 'keycloak')],
        [_keycloak],
      );

      expect(result.rows.single.label, const ProviderLabel('Keycloak'));
    });

    test('orders the password, then providers in discovery order, then '
        'removed providers', () {
      final result = _describe(
        [
          _method('gone', 'retired'),
          _method('g', 'github'),
          _method('k', 'keycloak'),
          _password(),
        ],
        [_keycloak, _github],
      );

      expect(result.rows.map((r) => r.method.id), ['pw', 'k', 'g', 'gone']);
    });

    test('linkable is every unlinked strategy, in discovery order', () {
      final other = _strategy('other');
      final result = _describe(
        [_method('g', 'github')],
        [_keycloak, _github, other],
      );

      expect(result.linkable, [_keycloak, other]);
    });

    test('no methods: nothing listed, every strategy linkable', () {
      final result = _describe([], [_keycloak]);

      expect(result.rows, isEmpty);
      expect(result.linkable, [_keycloak]);
    });
  });

  group('value equality', () {
    test('equal inputs give equal rows and labels', () {
      final a = _describe(
        [_password(), _method('a', 'keycloak'), _method('gone', 'retired')],
        [_keycloak],
      );
      final b = _describe(
        [_password(), _method('a', 'keycloak'), _method('gone', 'retired')],
        [_keycloak],
      );

      expect(a.rows, b.rows);
      expect(a.rows.first.hashCode, b.rows.first.hashCode);
      expect(const PasswordLabel(), const PasswordLabel());
      expect(const ProviderLabel('A'), const ProviderLabel('A'));
      expect(const ProviderLabel('A'), isNot(const ProviderLabel('B')));
      expect(const RemovedProviderLabel(), const RemovedProviderLabel());
      expect(const PasswordLabel(), isNot(const RemovedProviderLabel()));
    });

    test('rows differing in a flag are unequal', () {
      final alone = _describe(
        [_method('a', 'keycloak')],
        [_keycloak],
      ).rows.single;
      final withPassword = _describe(
        [_password(), _method('a', 'keycloak')],
        [_keycloak],
      ).rows[1];

      expect(alone, isNot(withPassword));
    });
  });
}
