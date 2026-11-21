import 'package:interfaces/src/repositories/auth_repository.dart';
import 'package:meta/meta.dart';

/// One way the signed-in user can sign in to the server: a password, or a
/// linked sign-in provider (#582).
@immutable
final class SignInMethod {
  const SignInMethod({
    required this.id,
    required this.providerId,
    this.linkedAt,
  });

  /// The `providerId` of the row that holds the user's password.
  static const passwordProviderId = 'credential';

  /// The row's own id. This, not [providerId], is what unlinking takes.
  final String id;

  /// The provider this row signs in through, or [passwordProviderId].
  final String providerId;

  /// When the row was created, or null when the server did not say.
  final DateTime? linkedAt;

  bool get isPassword => providerId == passwordProviderId;

  @override
  bool operator ==(Object other) =>
      other is SignInMethod &&
      other.id == id &&
      other.providerId == providerId &&
      other.linkedAt == linkedAt;

  @override
  int get hashCode => Object.hash(id, providerId, linkedAt);
}

/// Why linking or unlinking a sign-in provider was refused (#582).
///
/// [rateLimited] and [network] have no wire code: they name client-side
/// outcomes that the bloc maps from `AuthRateLimitedException` and
/// `AuthNetworkException`.
enum ProviderLinkFailureReason {
  needsRecentSignIn,
  alreadyLinkedElsewhere,
  emailUnconfirmed,
  lastSignInMethod,
  accessDenied,
  providerUnavailable,
  startAgain,
  rateLimited,
  network,
  generic;

  /// Maps a wire `error` / `code` to its reason. Case-sensitive. A code
  /// outside the table, including `email_does_not_match` and
  /// `ACCOUNT_NOT_FOUND`, is [generic].
  ///
  /// Link answers `PROVIDER_LINK_NEEDS_RECENT_SIGN_IN` for a stale session.
  /// Unlink's fresh-session refusal, `SESSION_NOT_FRESH`, maps to
  /// [needsRecentSignIn] too.
  ///
  /// Web's start route answers `PROVIDER_NOT_FOUND` for a provider that is
  /// down; a return trip still says so as `oauth_provider_not_found`.
  static ProviderLinkFailureReason forCode(String code) => switch (code) {
    'PROVIDER_LINK_NEEDS_RECENT_SIGN_IN' ||
    'SESSION_NOT_FRESH' => needsRecentSignIn,
    'account_already_linked_to_different_user' => alreadyLinkedElsewhere,
    'unable_to_link_account' => emailUnconfirmed,
    'FAILED_TO_UNLINK_LAST_ACCOUNT' => lastSignInMethod,
    'access_denied' => accessDenied,
    'oauth_provider_not_found' || 'PROVIDER_NOT_FOUND' => providerUnavailable,
    'state_mismatch' => startAgain,
    _ => generic,
  };
}

/// How a link attempt ended, as the page load that follows it reads it (#582).
sealed class ProviderLinkReturn {
  const ProviderLinkReturn(this.providerId);

  /// The provider the attempt was for.
  final String providerId;
}

/// The provider is now linked to the signed-in user.
final class ProviderLinkSucceeded extends ProviderLinkReturn {
  const ProviderLinkSucceeded(super.providerId);
}

/// The provider or the server refused the link.
final class ProviderLinkFailed extends ProviderLinkReturn {
  const ProviderLinkFailed(super.providerId, this.failure);

  final AuthProviderLinkException failure;
}
