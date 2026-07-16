import 'package:freezed_annotation/freezed_annotation.dart';

import 'auth_user.dart';

part 'auth_response.freezed.dart';
part 'auth_response.g.dart';

/// Response from BetterAuth sign-in and sign-up endpoints.
///
/// BetterAuth is session-based — there is no refresh token. [token] is the
/// session token that must be sent as `Authorization: Bearer <token>` on
/// mobile/desktop, or is managed automatically as an httpOnly cookie on web.
///
/// [user] is an [AuthUser] (the BetterAuth `/api/auth/*` shape), not the
/// canonical BGE `User`. Consumers needing only shared identity fields can
/// widen to [UserBase]; the full BGE `User` (with `role`,
/// `isServiceAccount`) is fetched from `/api/user/*` when needed.
///
/// The sign-in envelope also carries a `redirect` boolean, ignored here.
@freezed
abstract class AuthResponse with _$AuthResponse {
  const factory AuthResponse({
    /// BetterAuth session token.
    required String token,

    /// Authenticated user (BetterAuth shape).
    required AuthUser user,

    /// Session expiry. Populated from [BgeSessionResponse]; null immediately
    /// after sign-in until the session endpoint confirms it.
    DateTime? expiresAt,
  }) = _AuthResponse;

  factory AuthResponse.fromJson(Map<String, dynamic> json) =>
      _$AuthResponseFromJson(json);
}

/// Response from `GET /api/auth/get-session`.
///
/// A BetterAuth `/api/auth/*` endpoint, so [user] is an [AuthUser] and all
/// fields are camelCase on the wire (no snake_case renames).
@freezed
abstract class BgeSessionResponse with _$BgeSessionResponse {
  const factory BgeSessionResponse({
    required BgeSession session,
    required AuthUser user,
  }) = _BgeSessionResponse;

  factory BgeSessionResponse.fromJson(Map<String, dynamic> json) =>
      _$BgeSessionResponseFromJson(json);
}

/// Session object nested inside [BgeSessionResponse].
///
/// Emitted by BetterAuth in camelCase — the client's SnakeCaseInterceptor
/// only touches BGE's own routes, and only the well-known document is
/// snake_case. Field names therefore match the wire directly with no
/// `@JsonKey` renames.
@freezed
abstract class BgeSession with _$BgeSession {
  const factory BgeSession({
    required String id,
    required String token,
    required DateTime expiresAt,
    required String userId,
    String? ipAddress,
    String? userAgent,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _BgeSession;

  factory BgeSession.fromJson(Map<String, dynamic> json) =>
      _$BgeSessionFromJson(json);
}
