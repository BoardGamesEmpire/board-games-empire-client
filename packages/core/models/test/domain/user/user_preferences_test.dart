import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

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
      final preferences = UserPreferences(
        id: 'pref123',
        userId: 'user123',
        emailNotifications: {'friendRequests': true, 'gameInvites': false},
      );

      final json = preferences.toJson();

      expect(json['emailNotifications']['friendRequests'], isTrue);
      expect(json['emailNotifications']['gameInvites'], isFalse);
    });
  });
}
