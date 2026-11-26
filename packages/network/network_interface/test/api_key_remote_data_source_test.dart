import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:test/test.dart';

void main() {
  group('ApiKeyPatch (#1028)', () {
    test('isEmpty is true only with nothing to change', () {
      expect(const ApiKeyPatch().isEmpty, isTrue);
      expect(const ApiKeyPatch(confirmCritical: true).isEmpty, isTrue);
      expect(const ApiKeyPatch(enabled: false).isEmpty, isFalse);
      expect(const ApiKeyPatch(name: 'ci').isEmpty, isFalse);
      expect(const ApiKeyPatch(scopes: []).isEmpty, isFalse);
      expect(const ApiKeyPatch(expiresInDays: 30).isEmpty, isFalse);
    });

    test('compares by value', () {
      expect(
        const ApiKeyPatch(name: 'a', enabled: true),
        const ApiKeyPatch(name: 'a', enabled: true),
      );
      expect(
        const ApiKeyPatch(name: 'a').hashCode,
        const ApiKeyPatch(name: 'a').hashCode,
      );
      expect(const ApiKeyPatch(name: 'a'), isNot(const ApiKeyPatch(name: 'b')));
      expect(
        const ApiKeyPatch(scopes: [ApiKeyScope(slug: 's')]),
        const ApiKeyPatch(scopes: [ApiKeyScope(slug: 's')]),
      );
      expect(
        const ApiKeyPatch(confirmCritical: true),
        isNot(const ApiKeyPatch()),
      );
    });
  });

  group('ApiKeyCreate (#1028)', () {
    test('expires in 90 days and confirms nothing by default', () {
      const request = ApiKeyCreate(
        name: 'ci',
        grant: ApiKeyEverythingGrant(),
      );

      expect(request.expiresInDays, ApiKeyRemoteDataSource.defaultExpiryDays);
      expect(request.expiresInDays, 90);
      expect(request.confirmCritical, isFalse);
    });

    test('compares by value, grant included', () {
      expect(
        const ApiKeyCreate(
          name: 'ci',
          grant: ApiKeyScopesGrant([ApiKeyScope(slug: 's', resourceId: 'r')]),
        ),
        const ApiKeyCreate(
          name: 'ci',
          grant: ApiKeyScopesGrant([ApiKeyScope(slug: 's', resourceId: 'r')]),
        ),
      );
      expect(
        const ApiKeyCreate(name: 'ci', grant: ApiKeyEverythingGrant()),
        const ApiKeyCreate(name: 'ci', grant: ApiKeyEverythingGrant()),
      );
      expect(
        const ApiKeyCreate(name: 'ci', grant: ApiKeyEverythingGrant()),
        isNot(
          const ApiKeyCreate(name: 'ci', grant: ApiKeyScopesGrant([])),
        ),
      );
      expect(
        const ApiKeyCreate(name: 'ci', grant: ApiKeyEverythingGrant()),
        isNot(
          const ApiKeyCreate(
            name: 'ci',
            grant: ApiKeyEverythingGrant(),
            confirmCritical: true,
          ),
        ),
      );
    });
  });

  group('ApiKeyRemoteException (#1028)', () {
    final cause = StateError('underneath');
    // Built at run time, so the failures below are not const.
    final message = ['no', 'pe'].join();
    final failures = <ApiKeyRemoteException>[
      ApiKeyNotFoundException(
        message,
        statusCode: 404,
        cause: cause,
        apiMessage: 'gone',
      ),
      ApiKeyNeedsRecentSignInException(
        message,
        statusCode: 403,
        cause: cause,
        apiMessage: 'gone',
      ),
      ApiKeyCriticalNeedsConfirmationException(
        message,
        statusCode: 422,
        cause: cause,
        apiMessage: 'gone',
      ),
      ApiKeySessionRequiredException(
        message,
        statusCode: 403,
        cause: cause,
        apiMessage: 'gone',
      ),
      ApiKeyScopeNotGrantableException(
        message,
        statusCode: 422,
        cause: cause,
        apiMessage: 'gone',
        slug: 's',
      ),
      ApiKeyScopeNotPinnableException(
        message,
        statusCode: 422,
        cause: cause,
        apiMessage: 'gone',
        slug: 's',
      ),
      ApiKeyExpiryOutOfRangeException(
        message,
        statusCode: 422,
        cause: cause,
        apiMessage: 'gone',
        min: 1,
        max: 365,
      ),
      ApiKeyPermanentException(
        message,
        statusCode: 400,
        cause: cause,
        apiMessage: 'gone',
      ),
      ApiKeyTransientException(
        message,
        statusCode: 503,
        cause: cause,
        apiMessage: 'gone',
      ),
    ];

    test('every failure carries message, status, cause and apiMessage', () {
      for (final failure in failures) {
        expect(failure.message, message, reason: '$failure');
        expect(failure.statusCode, isNotNull, reason: '$failure');
        expect(failure.cause, same(cause), reason: '$failure');
        expect(failure.apiMessage, 'gone', reason: '$failure');
      }
    });

    test('apiMessage, status and cause are optional', () {
      const failure = ApiKeyTransientException('x');

      expect(failure.apiMessage, isNull);
      expect(failure.statusCode, isNull);
      expect(failure.cause, isNull);
    });

    test('toString names the failure and leaves the cause out', () {
      final text = failures.first.toString();

      expect(text, contains('ApiKeyNotFoundException'));
      expect(text, contains('404'));
      expect(text, isNot(contains('underneath')));
    });

    test('the coded failures keep their fields', () {
      const grantable = ApiKeyScopeNotGrantableException('x', slug: 's');
      const pinnable = ApiKeyScopeNotPinnableException('x', slug: 'p');
      const range = ApiKeyExpiryOutOfRangeException('x', min: 1, max: 365);

      expect(grantable.slug, 's');
      expect(pinnable.slug, 'p');
      expect(range.min, 1);
      expect(range.max, 365);
      expect(const ApiKeyScopeNotGrantableException('x').slug, isNull);
      expect(const ApiKeyExpiryOutOfRangeException('x').max, isNull);
    });
  });

  group('ApiKeyRemoteDataSource limits (#1028)', () {
    test('match the backend', () {
      expect(ApiKeyRemoteDataSource.defaultPageSize, 20);
      expect(ApiKeyRemoteDataSource.maxPageSize, 50);
      expect(ApiKeyRemoteDataSource.minExpiryDays, 1);
      expect(ApiKeyRemoteDataSource.maxExpiryDays, 365);
      expect(ApiKeyRemoteDataSource.maxNameLength, 32);
    });
  });
}
