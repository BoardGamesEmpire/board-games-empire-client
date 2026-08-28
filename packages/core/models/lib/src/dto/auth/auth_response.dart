import 'package:freezed_annotation/freezed_annotation.dart';

import 'auth_user.dart';

part 'auth_response.freezed.dart';
part 'auth_response.g.dart';

/// Printed in place of a session token by the redacting `toString`s below.
///
/// Deliberately the same literal `Redaction.defaultReplacement` uses, but
/// written out rather than imported: `models` depends on neither
/// `observability` nor Flutter, and one shared string does not justify
/// inverting that. If the two ever have to agree mechanically, move the
/// constant — don't add the dependency.
const String _redactedToken = '<redacted>';

/// Response from BetterAuth sign-in and sign-up endpoints.
///
/// BetterAuth is session-based — there is no refresh token. [token] is the
/// session token sent as `Authorization: Bearer <token>` on mobile and
/// desktop.
///
/// [user] is an [AuthUser] (the BetterAuth `/api/auth/*` shape), not the
/// canonical BGE `User`. Consumers needing only shared identity fields can
/// widen to [UserBase]; the full BGE `User` (with `role`,
/// `isServiceAccount`) is fetched from `/api/user/*` when needed.
///
/// The sign-in envelope also carries a `redirect` boolean, ignored here.
@Freezed(toStringOverride: false)
abstract class AuthResponse with _$AuthResponse {
  const AuthResponse._();

  const factory AuthResponse({
    /// BetterAuth session token, or null where this envelope carries no
    /// bearer credential.
    ///
    /// **Null is a supported shape, not a degraded one** (#291). Two cases
    /// produce it:
    ///
    /// - **Web.** The browser holds the session in an httpOnly cookie that
    ///   Dart cannot read, so web has no bearer credential to carry. It
    ///   used to carry the server-vended one anyway, for shape parity —
    ///   which put a live credential in Dart-reachable memory for nothing
    ///   to read, partly undoing the point of the httpOnly cookie.
    /// - **A server that granted no session.** BetterAuth's documented
    ///   `token: null` envelope, returned when email verification is
    ///   required or `autoSignIn` is off.
    ///
    /// Required, though nullable, so every construction site has to state
    /// which of those it means rather than inheriting a default. A consumer
    /// that genuinely needs the credential must reject null explicitly:
    /// `AuthRepositoryImpl` is the only one, and it treats a null here as a
    /// server contract violation.
    required String? token,

    /// Authenticated user (BetterAuth shape).
    required AuthUser user,

    /// Session expiry. Populated from [BgeSessionResponse]; null immediately
    /// after sign-in until the session endpoint confirms it.
    DateTime? expiresAt,
  }) = _AuthResponse;

  factory AuthResponse.fromJson(Map<String, dynamic> json) =>
      _$AuthResponseFromJson(json);

  /// Redacted (#291). The generated override printed [token] verbatim, and
  /// the sinks that can see an object's `toString` mask emails only — the
  /// BreadcrumbBuffer's message field (its *context* maps are key-redacted,
  /// but a message is not) and `UncaughtErrorRecord`, which is what a
  /// feedback report carries off the device.
  ///
  /// Null prints as `null` rather than as the marker: "this platform
  /// carried no credential" and "a credential was here and was hidden" are
  /// different facts, and on web the first is the one worth reading.
  @override
  String toString() =>
      'AuthResponse(token: ${token == null ? 'null' : _redactedToken}, '
      'user: $user, expiresAt: $expiresAt)';
}

/// Response from `GET /api/auth/get-session`.
///
/// A BetterAuth `/api/auth/*` endpoint, so [user] is an [AuthUser] and all
/// fields are camelCase on the wire (no snake_case renames).
///
/// Its generated `toString` needs no override of its own: it interpolates
/// [session], so [BgeSession]'s redaction covers it.
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
///
/// [token] here is **always** the real session token — this is the
/// authoritative server record. Only **native** reads it as a credential
/// (it is what `TokenStorageService` persists and the bearer header
/// carries); web parses this envelope for [expiresAt] and the user, and
/// drops the token (#291).
///
/// Kept non-nullable, and that is a statement about the wire as it is
/// today, not a permanent one. **BoardGamesEmpire/board-games-empire-backend#407
/// proposes omitting `token` for cookie-authenticated clients — if that
/// lands while this field is `required`, `BgeSessionResponse.fromJson`
/// throws on web, `getSession` maps it to "the session endpoint returned
/// an unreadable response", and web auth stops working entirely.** This
/// field has to go nullable first, in a client release that ships before
/// the server change.
///
/// The token is redacted in `toString` rather than removed (#291): unlike
/// [AuthResponse.token] there is a reader that needs it.
@Freezed(toStringOverride: false)
abstract class BgeSession with _$BgeSession {
  const BgeSession._();

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

  /// Redacted (#291), for the same reason as [AuthResponse.toString] and
  /// with more at stake: this field is the live credential on every
  /// platform, not just the one that had no use for it.
  ///
  /// Every other field is kept — the generated shape minus one value — so
  /// this stays as useful in a log as it was. Note that leaves [ipAddress]
  /// and [userAgent] printed, as they always were; if those need masking
  /// that is a privacy question about session metadata, not this one about
  /// a credential.
  @override
  String toString() =>
      'BgeSession(id: $id, token: $_redactedToken, expiresAt: $expiresAt, '
      'userId: $userId, ipAddress: $ipAddress, userAgent: $userAgent, '
      'createdAt: $createdAt, updatedAt: $updatedAt)';
}
