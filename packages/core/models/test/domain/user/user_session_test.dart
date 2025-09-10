import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

void main() {
  group('UserSession', () {
    test('tracks session validity', () {
      final now = DateTime.now();
      final session = UserSession(
        id: 'session123',
        authenticationId: 'auth123',
        token: 'token',
        lastActive: now,
        expiresAt: now.add(Duration(hours: 1)),
        isValid: true,
      );

      expect(session.isValid, isTrue);
      expect(session.expiresAt.isAfter(now), isTrue);
    });

    test('stores device info', () {
      final json = {
        'id': 'session123',
        'authenticationId': 'auth123',
        'token': 'jwt_token',
        'deviceInfo': {'platform': 'iOS', 'version': '15.0'},
        'lastActive': '2024-01-01T00:00:00Z',
        'expiresAt': '2024-01-02T00:00:00Z',
        'isValid': true,
      };

      final session = UserSession.fromJson(json);

      expect(session.deviceInfo?['platform'], 'iOS');
      expect(session.deviceInfo?['version'], '15.0');
    });
  });
}
