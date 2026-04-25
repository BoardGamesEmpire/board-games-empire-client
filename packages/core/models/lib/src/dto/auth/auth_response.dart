import 'package:freezed_annotation/freezed_annotation.dart';
import '../../domain/user/user.dart';

part 'auth_response.freezed.dart';
part 'auth_response.g.dart';

/// Response from BetterAuth sign-in and sign-up endpoints.
///
/// BetterAuth is session-based — there is no refresh token. [token] is the
/// session token that must be sent as `Authorization: Bearer <token>` on
/// mobile/desktop, or is managed automatically as an httpOnly cookie on web.
@freezed
abstract class AuthResponse with _$AuthResponse {
  const factory AuthResponse({
    /// BetterAuth session token.
    required String token,

    /// Authenticated user profile.
    required User user,

    /// Session expiry. Populated from [BgeSessionResponse]; null immediately
    /// after sign-in until the session endpoint confirms it.
    DateTime? expiresAt,
  }) = _AuthResponse;

  factory AuthResponse.fromJson(Map<String, dynamic> json) =>
      _$AuthResponseFromJson(json);
}

/// Response from `GET /api/auth/get-session`.
@freezed
abstract class BgeSessionResponse with _$BgeSessionResponse {
  const factory BgeSessionResponse({
    required BgeSession session,
    required User user,
  }) = _BgeSessionResponse;

  factory BgeSessionResponse.fromJson(Map<String, dynamic> json) =>
      _$BgeSessionResponseFromJson(json);
}

/// Session object nested inside [BgeSessionResponse].
@freezed
abstract class BgeSession with _$BgeSession {
  const factory BgeSession({
    required String id,
    required String token,
    @JsonKey(name: 'expires_at') required DateTime expiresAt,
    @JsonKey(name: 'user_id') required String userId,
    @JsonKey(name: 'ip_address') String? ipAddress,
    @JsonKey(name: 'user_agent') String? userAgent,
    @JsonKey(name: 'created_at') DateTime? createdAt,
    @JsonKey(name: 'updated_at') DateTime? updatedAt,
  }) = _BgeSession;

  factory BgeSession.fromJson(Map<String, dynamic> json) =>
      _$BgeSessionFromJson(json);
}
