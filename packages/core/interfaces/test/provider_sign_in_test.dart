import 'package:interfaces/repositories.dart';
import 'package:interfaces/services.dart';
import 'package:test/test.dart';

void main() {
  group('ProviderSignInFailureReason.forCode', () {
    const table = {
      'REGISTRATION_DISABLED': ProviderSignInFailureReason.registrationDisabled,
      'SIGN_IN_PROVIDER_EMAIL_UNVERIFIED':
          ProviderSignInFailureReason.emailUnverified,
      'account_not_linked': ProviderSignInFailureReason.accountNotLinked,
      'access_denied': ProviderSignInFailureReason.accessDenied,
      'oauth_provider_not_found':
          ProviderSignInFailureReason.providerUnavailable,
      // Web's start route, for a provider that is down (#583).
      'PROVIDER_NOT_FOUND': ProviderSignInFailureReason.providerUnavailable,
      'state_mismatch': ProviderSignInFailureReason.startAgain,
      'APP_SIGN_IN_REQUEST_INVALID': ProviderSignInFailureReason.startAgain,
      'APP_SIGN_IN_FLOW_INVALID': ProviderSignInFailureReason.startAgain,
      'APP_SIGN_IN_UNAVAILABLE': ProviderSignInFailureReason.startAgain,
      'APP_SIGN_IN_CODE_INVALID': ProviderSignInFailureReason.startAgain,
    };

    test('follows the locked mapping', () {
      for (final entry in table.entries) {
        expect(
          ProviderSignInFailureReason.forCode(entry.key),
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('maps everything else, including wire codes outside the table, to generic', () {
      for (final code in [
        'issuer_mismatch',
        'RATE_LIMITED',
        'BANNED_USER',
        'nope',
        '',
        'ACCESS_DENIED',
        'Account_Not_Linked',
        'provider_not_found',
      ]) {
        expect(
          ProviderSignInFailureReason.forCode(code),
          ProviderSignInFailureReason.generic,
          reason: code,
        );
      }
    });
  });

  group('AuthProviderSignInException', () {
    test('carries the reason and the wire code, with a default message', () {
      const e = AuthProviderSignInException(
        ProviderSignInFailureReason.accessDenied,
        code: 'access_denied',
      );
      expect(e.reason, ProviderSignInFailureReason.accessDenied);
      expect(e.code, 'access_denied');
      expect(e.message, 'The provider sign-in was refused.');
      expect(e, isA<AuthException>());
    });
  });

  test('UnsupportedProviderSignInBrowser is unsupported and refuses to open '
      'with the generic refusal the seam promises', () {
    const browser = UnsupportedProviderSignInBrowser();
    expect(browser.isSupported, isFalse);
    expect(
      () => browser.authenticate(
        url: Uri.parse('https://x'),
        callbackScheme: 'bge',
      ),
      throwsA(
        isA<AuthProviderSignInException>().having(
          (e) => e.reason,
          'reason',
          ProviderSignInFailureReason.generic,
        ),
      ),
    );
  });

  test('the availability variants carry what the screen needs', () {
    const ProviderSignInAvailability a = ProviderSignInAddressMismatch(
      'https://x',
    );
    expect((a as ProviderSignInAddressMismatch).configuredAddress, 'https://x');
  });
}
