import 'package:interfaces/repositories.dart';
import 'package:test/test.dart';

void main() {
  group('ProviderLinkFailureReason.forCode', () {
    const table = {
      'PROVIDER_LINK_NEEDS_RECENT_SIGN_IN':
          ProviderLinkFailureReason.needsRecentSignIn,
      // Unlink's fresh-session refusal (#582).
      'SESSION_NOT_FRESH': ProviderLinkFailureReason.needsRecentSignIn,
      'account_already_linked_to_different_user':
          ProviderLinkFailureReason.alreadyLinkedElsewhere,
      'unable_to_link_account': ProviderLinkFailureReason.emailUnconfirmed,
      'FAILED_TO_UNLINK_LAST_ACCOUNT':
          ProviderLinkFailureReason.lastSignInMethod,
      'access_denied': ProviderLinkFailureReason.accessDenied,
      'oauth_provider_not_found': ProviderLinkFailureReason.providerUnavailable,
      'PROVIDER_NOT_FOUND': ProviderLinkFailureReason.providerUnavailable,
      'state_mismatch': ProviderLinkFailureReason.startAgain,
    };

    test('follows the locked mapping', () {
      for (final entry in table.entries) {
        expect(
          ProviderLinkFailureReason.forCode(entry.key),
          entry.value,
          reason: entry.key,
        );
      }
    });

    test('reads every other code as generic', () {
      for (final code in [
        'email_does_not_match',
        'ACCOUNT_NOT_FOUND',
        'session_not_fresh',
        'access_Denied',
        '',
      ]) {
        expect(
          ProviderLinkFailureReason.forCode(code),
          ProviderLinkFailureReason.generic,
          reason: code,
        );
      }
    });
  });

  group('SignInMethod', () {
    test('isPassword is true only for the credential provider', () {
      expect(
        const SignInMethod(id: 'a', providerId: 'credential').isPassword,
        isTrue,
      );
      expect(
        const SignInMethod(id: 'b', providerId: 'authentik').isPassword,
        isFalse,
      );
    });

    test('compares by value over every field', () {
      final at = DateTime.utc(2026, 11, 19);
      final a = SignInMethod(id: 'a', providerId: 'authentik', linkedAt: at);
      final b = SignInMethod(id: 'a', providerId: 'authentik', linkedAt: at);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const SignInMethod(id: 'a', providerId: 'authentik')));
      expect(
        a,
        isNot(SignInMethod(id: 'x', providerId: 'authentik', linkedAt: at)),
      );
      expect(
        a,
        isNot(SignInMethod(id: 'a', providerId: 'github', linkedAt: at)),
      );
    });
  });
}
