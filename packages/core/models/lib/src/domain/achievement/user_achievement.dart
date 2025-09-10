import 'package:freezed_annotation/freezed_annotation.dart';

part 'user_achievement.freezed.dart';
part 'user_achievement.g.dart';

@freezed
abstract class UserAchievement with _$UserAchievement {
  const factory UserAchievement({
    required String id,
    required String userId,
    required String achievementId,
    required DateTime earnedAt,
    required int progress,
  }) = _UserAchievement;

  factory UserAchievement.fromJson(Map<String, dynamic> json) =>
      _$UserAchievementFromJson(json);
}
