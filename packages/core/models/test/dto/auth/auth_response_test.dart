import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

void main() {
  group('AuthResponse', () {
    test('includes user and tokens', () {
      final user = User(id: 'user123', username: 'johndoe');
      final response = AuthResponse(
        user: user,
        accessToken: 'access_token',
        refreshToken: 'refresh_token',
        expiresAt: DateTime.parse('2024-01-02T00:00:00Z'),
      );

      final json = response.toJson();

      expect(json['accessToken'], 'access_token');
      expect(json['refreshToken'], 'refresh_token');
      expect(json['user']['username'], 'johndoe');
    });
  });
}
