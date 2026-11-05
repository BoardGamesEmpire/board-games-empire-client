/// One native provider sign-in in flight (#583): everything its return is
/// checked against, and where its code is exchanged, kept together.
///
/// Held in memory only, by the repository of the server it was started on. A
/// return after the process died finds no attempt and is refused, and a
/// persisted verifier would be one more secret on disk.
///
/// Compared by identity: the repository asks whether the attempt it holds is
/// still this one. The constructor is deliberately not `const`, so no two
/// attempts can be the same object.
final class ProviderSignInAttempt {
  ProviderSignInAttempt({
    required this.state,
    required this.codeVerifier,
    required this.providerId,
    required this.tokenEndpoint,
    required this.issuerAddress,
  });

  /// Sent to the start route, and required back on the return.
  final String state;

  /// The PKCE verifier. Only its challenge leaves the device before the
  /// exchange.
  final String codeVerifier;

  /// The provider the attempt was started for.
  final String providerId;

  /// The absolute token route, recorded at the start. The code is exchanged
  /// here, never at an address the return or the currently selected server
  /// supplies.
  final Uri tokenEndpoint;

  /// The address discovery was fetched from. A return's `iss` must name it
  /// (RFC 9207 section 2.4).
  final String issuerAddress;
}
