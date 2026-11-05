import 'package:models/dto.dart';

/// How an attempt to sign in through a sign-in provider ended, when it ended
/// without a refusal (#583). A refusal is an [AuthProviderSignInException].
sealed class ProviderSignInOutcome {
  const ProviderSignInOutcome();
}

/// The provider authenticated the user and the server granted [session].
final class ProviderSignInCompleted extends ProviderSignInOutcome {
  const ProviderSignInCompleted(this.session);

  final AuthResponse session;
}

/// The user closed the browser tab before finishing, or, on web, stopped the
/// page from leaving for the provider. Not a failure.
final class ProviderSignInCancelled extends ProviderSignInOutcome {
  const ProviderSignInCancelled();
}

/// Whether this device can sign in through a provider on the current server
/// (#583).
sealed class ProviderSignInAvailability {
  const ProviderSignInAvailability();
}

final class ProviderSignInAvailable extends ProviderSignInAvailability {
  const ProviderSignInAvailable();
}

/// No in-app browser tab exists here (native platforms other than Android,
/// iOS and macOS).
final class ProviderSignInUnsupportedDevice extends ProviderSignInAvailability {
  const ProviderSignInUnsupportedDevice();
}

/// The address this server was added under is not the address it reports as
/// its own issuer, so the provider would send the user back to a different
/// server than the one the app is talking to.
final class ProviderSignInAddressMismatch extends ProviderSignInAvailability {
  const ProviderSignInAddressMismatch(this.configuredAddress);

  /// The issuer discovery reported.
  final String configuredAddress;
}

/// Why a provider sign-in was refused.
///
/// [rateLimited] and [network] have no wire code: they name client-side
/// outcomes that the bloc maps from [AuthRateLimitedException] and
/// [AuthNetworkException].
enum ProviderSignInFailureReason {
  registrationDisabled,
  emailUnverified,
  accountNotLinked,
  accessDenied,
  providerUnavailable,
  startAgain,
  rateLimited,
  network,
  generic;

  /// Maps a wire `error` / `code` to its reason. Case-sensitive. A code
  /// outside the table, including `issuer_mismatch`, `RATE_LIMITED` and
  /// `BANNED_USER`, is [generic].
  ///
  /// Web's start route answers `PROVIDER_NOT_FOUND` for a provider that is
  /// down; a return trip still says so as `oauth_provider_not_found`.
  static ProviderSignInFailureReason forCode(String code) => switch (code) {
    'REGISTRATION_DISABLED' => registrationDisabled,
    'SIGN_IN_PROVIDER_EMAIL_UNVERIFIED' => emailUnverified,
    'account_not_linked' => accountNotLinked,
    'access_denied' => accessDenied,
    'oauth_provider_not_found' || 'PROVIDER_NOT_FOUND' => providerUnavailable,
    'state_mismatch' ||
    'APP_SIGN_IN_REQUEST_INVALID' ||
    'APP_SIGN_IN_FLOW_INVALID' ||
    'APP_SIGN_IN_UNAVAILABLE' ||
    'APP_SIGN_IN_CODE_INVALID' => startAgain,
    _ => generic,
  };
}
