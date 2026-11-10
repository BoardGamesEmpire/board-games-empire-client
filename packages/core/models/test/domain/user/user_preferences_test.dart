import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  group('UserPreferences', () {
    test('applies default values', () {
      final json = {'id': 'pref123', 'userId': 'user123'};

      final preferences = UserPreferences.fromJson(json);

      expect(preferences.theme, 'system');
      expect(preferences.showOnlineStatus, isTrue);
      expect(preferences.defaultReviewVisibility, Visibility.private);
      expect(preferences.favoriteCategories, isEmpty);
    });

    test('handles notification preferences', () {
      const preferences = UserPreferences(
        id: 'pref123',
        userId: 'user123',
        emailNotifications: {'friendRequests': true, 'gameInvites': false},
      );

      final json = preferences.toJson();

      expect(
        (json['emailNotifications'] as Map<String, dynamic>)['friendRequests'],
        isTrue,
      );
      expect(
        (json['emailNotifications'] as Map<String, dynamic>)['gameInvites'],
        isFalse,
      );
    });
  });
}
