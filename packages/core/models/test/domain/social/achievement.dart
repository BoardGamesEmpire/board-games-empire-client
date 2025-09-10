import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

void main() {
  group('Achievement', () {
    test('tracks progress against threshold', () {
      final achievement = Achievement(
        id: 'ach123',
        name: 'Play 10 Games',
        description: 'Play 10 different board games',
        type: AchievementType.gamesPlayed,
        threshold: 10,
      );

      final userAchievement = UserAchievement(
        id: 'ua123',
        userId: 'user123',
        achievementId: achievement.id,
        earnedAt: DateTime.now(),
        progress: 7,
      );

      expect(userAchievement.progress < achievement.threshold, isTrue);
    });

    test('serializes AchievementType enum', () {
      final achievement = Achievement(
        id: 'ach123',
        name: 'Collector',
        description: 'Own 50 games',
        type: AchievementType.collector,
        threshold: 50,
      );

      final json = achievement.toJson();

      expect(json['type'], 'Collector');
    });
  });
}
