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

/// Discriminant values matching the backend [AuthStrategyType] enum wire values.
/// Values are snake_case per SnakeCaseInterceptor on the NestJS side.
abstract final class AuthStrategyType {
  static const String emailAndPassword = 'email_and_password';
  static const String oidc = 'oidc';
}

/// Sealed base for authentication strategies advertised by a BGE server via
/// the /.well-known/bge-identity discovery document.
///
/// This is distinct from [AuthStrategy], which records how a user historically
/// authenticated. [ServerAuthStrategy] describes what the server currently
/// offers for login/registration.
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
/// Corresponds to [EmailAndPasswordStrategyDto] on the NestJS backend.
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

  /// Absolute URL for email/password sign-in.
  /// POST `{ email, password }` to this endpoint.
  final String signInEndpoint;

  /// Absolute URL for email/password registration.
  /// Null when [signUpDisabled] is true.
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
/// Corresponds to [OidcStrategyDto] on the NestJS backend.
/// The client initiates the OAuth2 redirect by POSTing to [authorizationEndpoint]
/// with `{ providerId, callbackURL }`. BetterAuth handles the code exchange.
final class OidcStrategy extends ServerAuthStrategy {
  const OidcStrategy({
    required this.providerId,
    required this.discoveryUrl,
    required this.authorizationEndpoint,
  });

  factory OidcStrategy.fromJson(Map<String, dynamic> json) {
    return OidcStrategy(
      providerId: json['provider_id'] as String,
      discoveryUrl: json['discovery_url'] as String,
      authorizationEndpoint: json['authorization_endpoint'] as String,
    );
  }

  /// Provider identifier passed to BetterAuth's oauth2 sign-in endpoint.
  final String providerId;

  /// Public OIDC well-known discovery URL.
  /// Clients may inspect this for scopes, PKCE requirements, etc.
  final String discoveryUrl;

  /// Absolute endpoint to initiate the OAuth2/OIDC redirect flow.
  /// POST `{ providerId, callbackURL }` to begin authentication.
  final String authorizationEndpoint;

  @override
  Map<String, dynamic> toJson() => {
    'type': AuthStrategyType.oidc,
    'provider_id': providerId,
    'discovery_url': discoveryUrl,
    'authorization_endpoint': authorizationEndpoint,
  };

  @override
  List<Object?> get props => [providerId, discoveryUrl, authorizationEndpoint];
}
