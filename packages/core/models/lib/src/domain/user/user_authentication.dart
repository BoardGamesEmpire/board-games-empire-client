import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/user/auth_strategy.dart';

part 'user_authentication.freezed.dart';
part 'user_authentication.g.dart';

@freezed
abstract class UserAuthentication with _$UserAuthentication {
  const factory UserAuthentication({
    required String id,
    required String userId,
    required String email,
    required AuthStrategy authStrategy,
    required bool emailVerified,
    required bool accountLocked,
    required int failedLoginAttempts,
    required bool twoFactorEnabled,
    required bool isExternalUser,
    DateTime? lastPasswordChange,
    DateTime? accountLockedUntil,
    DateTime? lastFailedLogin,
    DateTime? lastLogin,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _UserAuthentication;

  factory UserAuthentication.fromJson(Map<String, dynamic> json) =>
      _$UserAuthenticationFromJson(json);
}
