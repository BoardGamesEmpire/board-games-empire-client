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
///
/// ## Endpoint paths are relative
///
/// Endpoint fields ([sessionEndpoint], [signOutEndpoint],
/// [deviceAuthorizationEndpoint], and the per-strategy endpoints on
/// [ServerAuthStrategy]) are **relative paths** (e.g. `/api/auth/get-session`).
/// They are resolved against the user-supplied server base URL
/// (`ServerConfig.serverUrl`) by the per-server `Dio` instance built by the
/// `DioFactory`. The client already knows the base — the user typed it to reach
/// well-known in the first place — so the document never needs to repeat an
/// absolute origin. [discoveryUrl] on an [OidcStrategy] is the one exception:
/// it points at an external identity provider and remains absolute.
@freezed
abstract class ServerIdentity with _$ServerIdentity {
  const ServerIdentity._();

  const factory ServerIdentity({
    /// Schema version of the discovery document. Bumped only on a breaking
    /// shape change; the client refuses documents newer than it understands
    /// (enforced by the version negotiator, #13).
    @JsonKey(name: 'well_known_schema_version')
    required int wellKnownSchemaVersion,

    /// Stable UUID identifying this BGE server instance.
    /// Corresponds to the `bge_server_id` field in [BgeDiscoveryDto].
    @JsonKey(name: 'bge_server_id') required String serverId,

    /// Human-readable server display name, shown when choosing which server
    /// to add. Also the default alias suggestion in the server-add flow
    /// (#36).
    required String name,

    /// Minimum semver client version this server accepts. Clients older
    /// than this refuse to proceed past server-add. Null = no minimum.
    /// Compared against [BuildInfo.version] by the version negotiator (#13).
    @JsonKey(name: 'bge_min_client_version') String? minClientVersion,

    /// Maximum semver client version this server accepts. Clients newer
    /// than this refuse to proceed. Null = no maximum.
    @JsonKey(name: 'bge_max_client_version') String? maxClientVersion,

    /// Canonical base URL of this BGE server. Equivalent to `issuer` in
    /// RFC 8414. Informational only: used to confirm the client is talking to
    /// the expected server and to detect URL changes that require user
    /// confirmation. Request URLs are built from the user-supplied base
    /// (`ServerConfig.serverUrl`), not from this field.
    required String issuer,

    /// Device authorization endpoint per RFC 8628.
    /// Relative path resolved against the user-supplied server base URL.
    @JsonKey(name: 'device_authorization_endpoint')
    required String deviceAuthorizationEndpoint,

    /// BetterAuth base path (relative to the server base URL). Used to
    /// construct any auth endpoint not listed explicitly in this document.
    /// Renamed from `bge_auth_base_url` on the wire to make the relative
    /// semantics explicit.
    @JsonKey(name: 'bge_auth_base_path') required String authBasePath,

    /// Endpoint to retrieve the current user session.
    /// GET — returns session data if authenticated, 401 if not.
    /// Relative path resolved against the user-supplied server base URL.
    @JsonKey(name: 'bge_session_endpoint') required String sessionEndpoint,

    /// Endpoint to terminate the current session.
    /// POST — invalidates the session token.
    /// Relative path resolved against the user-supplied server base URL.
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
