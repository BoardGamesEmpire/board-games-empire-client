import 'package:freezed_annotation/freezed_annotation.dart';

part 'user_login_history.freezed.dart';
part 'user_login_history.g.dart';

@freezed
abstract class UserLoginHistory with _$UserLoginHistory {
  const factory UserLoginHistory({
    required String id,
    required String authenticationId,
    String? ipAddress,
    String? userAgent,
    required bool success,
    String? failureReason,
    required DateTime createdAt,
  }) = _UserLoginHistory;

  factory UserLoginHistory.fromJson(Map<String, dynamic> json) =>
      _$UserLoginHistoryFromJson(json);
}
