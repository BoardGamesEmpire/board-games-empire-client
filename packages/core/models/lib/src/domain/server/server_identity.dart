import 'package:freezed_annotation/freezed_annotation.dart';
import 'server_auth_strategy.dart';

part 'server_identity.freezed.dart';
part 'server_identity.g.dart';

/// Immutable representation of the BGE server discovery document served at
/// /.well-known/bge-identity.
///
/// Modeled directly from [BgeDiscoveryDto] on the NestJS backend. All fields
/// use explicit [JsonKey] names to match the snake_case wire format produced
/// by the backend's SnakeCaseInterceptor.
///
/// [serverId] is the stable UUID identifying this server instance across URL
/// changes. The client stores it in the root DB and uses it to detect
/// "same server, new URL" scenarios — requiring user confirmation before
/// updating the stored URL.
@freezed
abstract class ServerIdentity with _$ServerIdentity {
  const ServerIdentity._();

  const factory ServerIdentity({
    /// Stable UUID identifying this BGE server instance.
    /// Corresponds to the `bge_server_id` field in [BgeDiscoveryDto].
    @JsonKey(name: 'bge_server_id') required String serverId,

    /// Canonical base URL of this BGE server. Equivalent to `issuer` in
    /// RFC 8414. Clients use this to confirm they are talking to the expected
    /// server and to detect URL changes that require user confirmation.
    required String issuer,

    /// Device authorization endpoint per RFC 8628.
    @JsonKey(name: 'device_authorization_endpoint')
    required String deviceAuthorizationEndpoint,

    /// BetterAuth base URL. Used to construct any auth endpoint not listed
    /// explicitly in this document.
    @JsonKey(name: 'bge_auth_base_url') required String authBaseUrl,

    /// Endpoint to retrieve the current user session.
    /// GET — returns session data if authenticated, 401 if not.
    @JsonKey(name: 'bge_session_endpoint') required String sessionEndpoint,

    /// Endpoint to terminate the current session.
    /// POST — invalidates the session token.
    @JsonKey(name: 'bge_sign_out_endpoint') required String signOutEndpoint,

    /// Whether passkey (WebAuthn) authentication is supported.
    @JsonKey(name: 'bge_passkey_supported') required bool passkeySupported,

    /// Whether two-factor authentication is supported.
    /// After primary sign-in, clients may be required to complete a 2FA step.
    @JsonKey(name: 'bge_two_factor_supported') required bool twoFactorSupported,

    /// Whether anonymous authentication is supported.
    /// Anonymous sessions can later be linked to a real account.
    @JsonKey(name: 'bge_anonymous_auth_supported')
    required bool anonymousAuthSupported,

    /// Authentication strategies currently enabled on this server.
    /// An empty list means only device flow or passkey authentication is
    /// available. Deserialized via [ServerAuthStrategyListConverter].
    @ServerAuthStrategyListConverter()
    @Default([])
    List<ServerAuthStrategy> strategies,
  }) = _ServerIdentity;

  factory ServerIdentity.fromJson(Map<String, dynamic> json) =>
      _$ServerIdentityFromJson(json);

  /// Whether email/password authentication is advertised by this server.
  bool get hasEmailAndPassword =>
      strategies.any((s) => s is EmailAndPasswordStrategy);

  /// Whether OIDC authentication is advertised by this server.
  bool get hasOidc => strategies.any((s) => s is OidcStrategy);

  /// The email/password strategy, if present. Null otherwise.
  EmailAndPasswordStrategy? get emailAndPasswordStrategy =>
      strategies.whereType<EmailAndPasswordStrategy>().firstOrNull;

  /// All OIDC strategies. A server may advertise multiple OIDC providers.
  List<OidcStrategy> get oidcStrategies =>
      strategies.whereType<OidcStrategy>().toList();
}
