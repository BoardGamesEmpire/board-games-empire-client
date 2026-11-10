import 'package:equatable/equatable.dart';
import 'package:json_annotation/json_annotation.dart';

/// JsonConverter for deserializing the polymorphic strategies array from the
/// /.well-known/bge-identity response.
///
/// The wire format uses a `type` discriminant field with snake_case values
/// matching [AuthStrategyType] constants.
class ServerAuthStrategyListConverter
    implements JsonConverter<List<ServerAuthStrategy>, List<dynamic>> {
  const ServerAuthStrategyListConverter();

  @override
  List<ServerAuthStrategy> fromJson(List<dynamic> json) => json
      .map((e) => ServerAuthStrategy.fromJson(e as Map<String, dynamic>))
      .toList();

  @override
  List<dynamic> toJson(List<ServerAuthStrategy> strategies) =>
      strategies.map((s) => s.toJson()).toList();
}

/// Discriminant values matching the backend [AuthStrategyType] enum wire
/// values.
/// Values are snake_case per SnakeCaseInterceptor on the NestJS side.
abstract final class AuthStrategyType {
  static const String emailAndPassword = 'email_and_password';
  static const String oidc = 'oidc';
}

/// Sealed base for authentication strategies advertised by a BGE server via
/// the /.well-known/bge-identity discovery document.
///
/// This is distinct from `AuthStrategy`, which records how a user historically
/// authenticated. [ServerAuthStrategy] describes what the server currently
/// offers for login/registration.
///
/// Endpoint fields are relative paths resolved against the user-supplied server
/// base URL (`ServerConfig.serverUrl`) by the per-server `Dio`. The exception
/// is [OidcStrategy.discoveryUrl], which targets an external identity provider
/// and is absolute.
///
/// Use a `switch` expression to exhaustively handle all variants:
/// ```dart
/// final label = switch (strategy) {
///   EmailAndPasswordStrategy() => 'Email & Password',
///   OidcStrategy(providerId: final id) => 'SSO: $id',
/// };
/// ```
sealed class ServerAuthStrategy extends Equatable {
  const ServerAuthStrategy();

  /// Deserializes a strategy from the well-known wire format.
  ///
  /// Dispatches on the `type` field using [AuthStrategyType] constants.
  /// Throws [FormatException] for unknown type values.
  factory ServerAuthStrategy.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    return switch (type) {
      AuthStrategyType.emailAndPassword => EmailAndPasswordStrategy.fromJson(
        json,
      ),
      AuthStrategyType.oidc => OidcStrategy.fromJson(json),
      _ => throw FormatException(
        'Unknown auth strategy type: "$type". '
        'Expected one of: ${AuthStrategyType.emailAndPassword}, '
        '${AuthStrategyType.oidc}',
      ),
    };
  }

  Map<String, dynamic> toJson();
}

/// Email and password authentication strategy.
///
/// Corresponds to `EmailAndPasswordStrategyDto` on the NestJS backend.
/// When [signUpDisabled] is true, [signUpEndpoint] will be null and the
/// client should hide or disable the registration flow.
final class EmailAndPasswordStrategy extends ServerAuthStrategy {
  const EmailAndPasswordStrategy({
    required this.signUpDisabled,
    required this.signInEndpoint,
    this.signUpEndpoint,
  });

  factory EmailAndPasswordStrategy.fromJson(Map<String, dynamic> json) {
    return EmailAndPasswordStrategy(
      signUpDisabled: json['sign_up_disabled'] as bool,
      signInEndpoint: json['sign_in_endpoint'] as String,
      signUpEndpoint: json['sign_up_endpoint'] as String?,
    );
  }

  /// Whether new account registration via email/password is disabled.
  /// When true, only sign-in is available via this strategy.
  final bool signUpDisabled;

  /// Relative path for email/password sign-in, resolved against the
  /// user-supplied server base URL. POST `{ email, password }` to this path.
  final String signInEndpoint;

  /// Relative path for email/password registration, resolved against the
  /// user-supplied server base URL. Null when [signUpDisabled] is true.
  final String? signUpEndpoint;

  @override
  Map<String, dynamic> toJson() => {
    'type': AuthStrategyType.emailAndPassword,
    'sign_up_disabled': signUpDisabled,
    'sign_in_endpoint': signInEndpoint,
    if (signUpEndpoint != null) 'sign_up_endpoint': signUpEndpoint,
  };

  @override
  List<Object?> get props => [signUpDisabled, signInEndpoint, signUpEndpoint];
}

/// OIDC (OpenID Connect) authentication strategy.
///
/// Corresponds to `OidcStrategyDto` on the NestJS backend. One strategy is one
/// provider the server lets people sign in through (#583).
///
/// Two flows use it:
/// - Web: the client POSTs [authorizationEndpoint] with
///   `{ provider, callbackURL, errorCallbackURL }`, navigates to the returned
///   URL, and the server sets the session cookie on the way back.
/// - Native: the client opens [appSignInEndpoint] in an in-app browser tab
///   with a PKCE challenge and a `state`; the server returns to `bge://oauth`
///   with a one-time code, and the client POSTs [appTokenEndpoint] with
///   `{ code, code_verifier }` for `{ token, user }`.
final class OidcStrategy extends ServerAuthStrategy {
  const OidcStrategy({
    required this.providerId,
    required this.displayName,
    required this.discoveryUrl,
    required this.authorizationEndpoint,
    required this.appSignInEndpoint,
    required this.appTokenEndpoint,
    this.signUpDisabled = false,
  });

  factory OidcStrategy.fromJson(Map<String, dynamic> json) {
    return OidcStrategy(
      signUpDisabled: json['sign_up_disabled'] as bool? ?? false,
      providerId: json['provider_id'] as String,
      displayName: json['display_name'] as String,
      discoveryUrl: json['discovery_url'] as String,
      authorizationEndpoint: json['authorization_endpoint'] as String,
      appSignInEndpoint: json['app_sign_in_endpoint'] as String,
      appTokenEndpoint: json['app_token_endpoint'] as String,
    );
  }

  /// Whether a first sign-in, which would create the account, is refused.
  ///
  /// Existing accounts still sign in through the provider, so the strategy
  /// stays listed either way. Optional on the wire: a server older than
  /// backend#585 doesn't send it, and failing the whole discovery parse over
  /// it would report a working server as an invalid one (#443). Nothing reads
  /// it yet (#583).
  final bool signUpDisabled;

  /// Provider identifier, sent as `provider` to both sign-in flows.
  final String providerId;

  /// The provider's name as the server shows it, for the sign-in button.
  final String displayName;

  /// Public OIDC well-known discovery URL. Absolute — this points at the
  /// external identity provider, not the BGE server. Clients may inspect this
  /// for scopes, PKCE requirements, etc.
  final String discoveryUrl;

  /// Relative path for the web flow, resolved against the user-supplied server
  /// base URL. POST `{ provider, callbackURL, errorCallbackURL }` to begin
  /// authentication; the answer carries the URL to navigate to.
  final String authorizationEndpoint;

  /// Relative path the native flow opens in an in-app browser tab, resolved
  /// against the user-supplied server base URL. A GET carrying `provider`,
  /// `redirect_uri`, `code_challenge`, `code_challenge_method` and `state`.
  final String appSignInEndpoint;

  /// Relative path the native flow exchanges the returned one-time code at,
  /// resolved against the user-supplied server base URL. POST
  /// `{ code, code_verifier }` for `{ token, user }`.
  final String appTokenEndpoint;

  @override
  Map<String, dynamic> toJson() => {
    'type': AuthStrategyType.oidc,
    'sign_up_disabled': signUpDisabled,
    'provider_id': providerId,
    'display_name': displayName,
    'discovery_url': discoveryUrl,
    'authorization_endpoint': authorizationEndpoint,
    'app_sign_in_endpoint': appSignInEndpoint,
    'app_token_endpoint': appTokenEndpoint,
  };

  @override
  List<Object?> get props => [
    signUpDisabled,
    providerId,
    displayName,
    discoveryUrl,
    authorizationEndpoint,
    appSignInEndpoint,
    appTokenEndpoint,
  ];
}
