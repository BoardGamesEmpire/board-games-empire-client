import 'package:freezed_annotation/freezed_annotation.dart';

import 'package:models/src/domain/achievement/achievement_type.dart';

part 'achievement.freezed.dart';
part 'achievement.g.dart';

@freezed
abstract class Achievement with _$Achievement {
  const factory Achievement({
    required String id,
    required String name,
    required String description,
    required AchievementType type,
    required int threshold,
    String? icon,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _Achievement;

  factory Achievement.fromJson(Map<String, dynamic> json) =>
      _$AchievementFromJson(json);
}
