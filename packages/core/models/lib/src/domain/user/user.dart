import 'package:freezed_annotation/freezed_annotation.dart';

import 'user_base.dart';

part 'user.freezed.dart';
part 'user.g.dart';

/// The canonical BGE domain user, returned by `/api/user/*` and embedded in
/// relations (household member → user, collection owner, etc.).
///
/// Mirrors the backend `User` scalar fields. Distinct from [AuthUser] (the
/// BetterAuth `/api/auth/*` shape): this contract names the display field
/// `username` on the wire and carries the BGE-only [role] and
/// [isServiceAccount]. Both implement [UserBase].
///
/// Wire format is camelCase (only the well-known document is snake_case),
/// so no `@JsonKey` renames are needed. There is no `avatar` / `profileImage`
/// / `bio` on the backend user — the avatar field is [image]; profile-only
/// fields live on the separate `UserProfile` relation.
@freezed
abstract class User with _$User implements UserBase {
  const factory User({
    required String id,
    required String username,
    required String email,
    required bool emailVerified,
    String? image,
    String? firstName,
    String? lastName,
    bool? banned,
    String? banReason,
    DateTime? banExpires,
    bool? isAnonymous,

    /// BGE-only: distinguishes service accounts from human users. Not part
    /// of [UserBase] (absent from the auth shape).
    bool? isServiceAccount,
    bool? twoFactorEnabled,

    /// BGE-only free-form role string. BGE's real authorization lives in
    /// permission/role join tables; this mirrors the backend column but is
    /// not part of [UserBase] (the auth user omits it).
    String? role,
    required DateTime createdAt,
    required DateTime updatedAt,
  }) = _User;

  factory User.fromJson(Map<String, dynamic> json) => _$UserFromJson(json);
}
