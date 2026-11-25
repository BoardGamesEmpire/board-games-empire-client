import 'package:api_keys/api_keys.dart';
import 'package:api_keys/l10n/api_keys_localizations_en.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

void main() {
  final l10n = ApiKeysLocalizationsEn();

  group('apiKeyFailureOf', () {
    test('apiKeyFailureOf maps each exception and keeps slug, min and max', () {
      expect(
        apiKeyFailureOf(const ApiKeyNeedsRecentSignInException('m')),
        const ApiKeyFailure(ApiKeyFailureReason.needsRecentSignIn),
      );
      expect(
        apiKeyFailureOf(const ApiKeyCriticalNeedsConfirmationException('m')),
        const ApiKeyFailure(ApiKeyFailureReason.criticalNeedsConfirmation),
      );
      expect(
        apiKeyFailureOf(
          const ApiKeyScopeNotGrantableException('m', slug: 'users:manage'),
        ),
        const ApiKeyFailure(
          ApiKeyFailureReason.scopeNotGrantable,
          slug: 'users:manage',
        ),
      );
      expect(
        apiKeyFailureOf(
          const ApiKeyScopeNotPinnableException('m', slug: 'households:manage'),
        ),
        const ApiKeyFailure(
          ApiKeyFailureReason.scopeNotPinnable,
          slug: 'households:manage',
        ),
      );
      expect(
        apiKeyFailureOf(
          const ApiKeyExpiryOutOfRangeException('m', min: 1, max: 365),
        ),
        const ApiKeyFailure(
          ApiKeyFailureReason.expiryOutOfRange,
          min: 1,
          max: 365,
        ),
      );
      expect(
        apiKeyFailureOf(const ApiKeyNotFoundException('m')),
        const ApiKeyFailure(ApiKeyFailureReason.notFound),
      );
      expect(
        apiKeyFailureOf(const ApiKeyTransientException('m')),
        const ApiKeyFailure(ApiKeyFailureReason.transient),
      );
      expect(
        apiKeyFailureOf(const ApiKeyPermanentException('m')),
        const ApiKeyFailure(ApiKeyFailureReason.generic),
      );
      // Keys are managed from a signed-in session only. The client has no
      // words of its own for that, so it is generic, with the server's.
      expect(
        apiKeyFailureOf(const ApiKeySessionRequiredException('m')),
        const ApiKeyFailure(ApiKeyFailureReason.generic),
      );
      expect(
        apiKeyFailureOf(StateError('boom')),
        const ApiKeyFailure(ApiKeyFailureReason.generic),
      );
    });

    test('every failure keeps the server message', () {
      const said = 'Said by the server.';
      for (final error in const <ApiKeyRemoteException>[
        ApiKeyNeedsRecentSignInException('m', apiMessage: said),
        ApiKeyCriticalNeedsConfirmationException('m', apiMessage: said),
        ApiKeyScopeNotGrantableException('m', apiMessage: said),
        ApiKeyScopeNotPinnableException('m', apiMessage: said),
        ApiKeyExpiryOutOfRangeException('m', apiMessage: said),
        ApiKeyNotFoundException('m', apiMessage: said),
        ApiKeyTransientException('m', apiMessage: said),
        ApiKeyPermanentException('m', apiMessage: said),
        ApiKeySessionRequiredException('m', apiMessage: said),
      ]) {
        expect(apiKeyFailureOf(error).serverMessage, said, reason: '$error');
      }
    });

    test('a failure that is not the remote has no server message', () {
      expect(apiKeyFailureOf(StateError('boom')).serverMessage, isNull);
    });
  });

  group('apiKeyFailureMessage', () {
    String message(
      ApiKeyFailure failure, {
      Map<String, GrantablePermission>? grantable,
    }) => apiKeyFailureMessage(l10n, failure, grantable: grantable);

    test('a generic refusal shows the server message', () {
      expect(
        message(
          const ApiKeyFailure(
            ApiKeyFailureReason.generic,
            serverMessage: 'Name must be shorter.',
          ),
        ),
        'Name must be shorter.',
      );
    });

    test('a generic refusal with no server message shows the client copy', () {
      expect(
        message(const ApiKeyFailure(ApiKeyFailureReason.generic)),
        l10n.apiKeyFailureGeneric,
      );
      expect(
        message(
          const ApiKeyFailure(ApiKeyFailureReason.generic, serverMessage: ' '),
        ),
        l10n.apiKeyFailureGeneric,
      );
    });

    test('a refusal with client copy of its own keeps it', () {
      const said = 'Said by the server.';
      expect(
        message(
          const ApiKeyFailure(
            ApiKeyFailureReason.needsRecentSignIn,
            serverMessage: said,
          ),
        ),
        l10n.apiKeyFailureNeedsRecentSignIn,
      );
      expect(
        message(
          const ApiKeyFailure(
            ApiKeyFailureReason.transient,
            serverMessage: said,
          ),
        ),
        l10n.apiKeyFailureTransient,
      );
      expect(
        message(
          const ApiKeyFailure(
            ApiKeyFailureReason.notFound,
            serverMessage: said,
          ),
        ),
        l10n.apiKeyFailureNotFound,
      );
      expect(
        message(
          const ApiKeyFailure(
            ApiKeyFailureReason.criticalNeedsConfirmation,
            serverMessage: said,
          ),
        ),
        l10n.apiKeyFailureCriticalNeedsConfirmation,
      );
    });

    test('a refused scope is named by its description, else its slug', () {
      const failure = ApiKeyFailure(
        ApiKeyFailureReason.scopeNotGrantable,
        slug: 'users:manage',
      );
      expect(
        message(
          failure,
          grantable: {
            'users:manage': const GrantablePermission(
              slug: 'users:manage',
              description: 'Manage users',
              riskLevel: RiskLevel.critical,
              pinnable: false,
            ),
          },
        ),
        "You can't give a key the permission Manage users.",
      );
      expect(
        message(failure),
        "You can't give a key the permission users:manage.",
      );
      expect(
        message(
          const ApiKeyFailure(
            ApiKeyFailureReason.scopeNotPinnable,
            slug: 'households:manage',
          ),
        ),
        "The permission households:manage can't be limited to one record.",
      );
      expect(
        message(const ApiKeyFailure(ApiKeyFailureReason.scopeNotGrantable)),
        l10n.apiKeyFailureScopeUnnamed,
      );
    });

    test('an expiry out of range names the range, with plurals', () {
      expect(
        message(
          const ApiKeyFailure(
            ApiKeyFailureReason.expiryOutOfRange,
            min: 1,
            max: 365,
          ),
        ),
        'A key can last from 1 day to 365 days.',
      );
      // A body that named no range falls back to the client's own.
      expect(
        message(const ApiKeyFailure(ApiKeyFailureReason.expiryOutOfRange)),
        'A key can last from 1 day to 365 days.',
      );
    });
  });

  test('ApiKeyFailure compares by value', () {
    expect(
      const ApiKeyFailure(ApiKeyFailureReason.generic, serverMessage: 'a'),
      isNot(
        const ApiKeyFailure(ApiKeyFailureReason.generic, serverMessage: 'b'),
      ),
    );
    expect(
      const ApiKeyFailure(
        ApiKeyFailureReason.scopeNotGrantable,
        slug: 'x',
      ).hashCode,
      const ApiKeyFailure(
        ApiKeyFailureReason.scopeNotGrantable,
        slug: 'x',
      ).hashCode,
    );
  });
}
