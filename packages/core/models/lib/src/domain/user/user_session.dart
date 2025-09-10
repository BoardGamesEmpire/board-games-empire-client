import 'package:freezed_annotation/freezed_annotation.dart';

part 'user_session.freezed.dart';
part 'user_session.g.dart';

@freezed
abstract class UserSession with _$UserSession {
  const factory UserSession({
    required String id,
    required String authenticationId,
    required String token,
    Map<String, dynamic>? deviceInfo,
    String? ipAddress,
    String? userAgent,
    required DateTime lastActive,
    required DateTime expiresAt,
    required bool isValid,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _UserSession;

  factory UserSession.fromJson(Map<String, dynamic> json) =>
      _$UserSessionFromJson(json);
}
