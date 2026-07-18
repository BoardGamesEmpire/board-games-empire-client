import 'package:freezed_annotation/freezed_annotation.dart';

import '../../domain/user/user_base.dart';

part 'auth_user.freezed.dart';
part 'auth_user.g.dart';

/// The user object returned by BetterAuth's `/api/auth/*` endpoints
/// (sign-in, sign-up, get-session).
///
/// This is deliberately distinct from the canonical BGE `User` (returned
/// by `/api/user/*` and relations): BetterAuth names the display field
/// `name` on the wire and does not return BGE's `role` / `isServiceAccount`
/// (roles/permissions are modeled in BGE join tables, not on the auth
/// user). Both implement [UserBase] so shared-field consumers can treat
/// them uniformly.
///
/// Wire format is camelCase (only the well-known document is snake_case),
/// so no key renames are needed except mapping `name` → [username].
/// `role` and `isServiceAccount` are intentionally not modeled here.
@freezed
abstract class AuthUser with _$AuthUser implements UserBase {
  const factory AuthUser({
    required String id,

    /// BetterAuth returns the display name under `name`; it is BGE's
    /// username.
    @JsonKey(name: 'name') required String username,

    required String email,
    required bool emailVerified,
    String? image,
    String? firstName,
    String? lastName,
    bool? banned,
    String? banReason,
    DateTime? banExpires,
    bool? isAnonymous,
    bool? twoFactorEnabled,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _AuthUser;

  factory AuthUser.fromJson(Map<String, dynamic> json) =>
      _$AuthUserFromJson(json);
}
