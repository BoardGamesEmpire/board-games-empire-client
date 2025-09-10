import 'package:freezed_annotation/freezed_annotation.dart';

part 'user_external_identity.freezed.dart';
part 'user_external_identity.g.dart';

@freezed
abstract class UserExternalIdentity with _$UserExternalIdentity {
  const factory UserExternalIdentity({
    required String id,
    required String authenticationId,
    required String providerId,
    required String externalId,
    String? email,
    Map<String, dynamic>? rawProfile,
    String? accessToken,
    String? refreshToken,
    DateTime? tokenExpiresAt,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _UserExternalIdentity;

  factory UserExternalIdentity.fromJson(Map<String, dynamic> json) =>
      _$UserExternalIdentityFromJson(json);
}
