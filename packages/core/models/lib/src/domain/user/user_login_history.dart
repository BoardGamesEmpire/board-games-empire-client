import 'package:freezed_annotation/freezed_annotation.dart';

part 'user_login_history.freezed.dart';
part 'user_login_history.g.dart';

@freezed
abstract class UserLoginHistory with _$UserLoginHistory {
  const factory UserLoginHistory({
    required String id,
    required String authenticationId,
    required bool success,
    required DateTime createdAt,
    String? ipAddress,
    String? userAgent,
    String? failureReason,
  }) = _UserLoginHistory;

  factory UserLoginHistory.fromJson(Map<String, dynamic> json) =>
      _$UserLoginHistoryFromJson(json);
}
