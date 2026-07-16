import 'package:flutter_test/flutter_test.dart';

import 'package:models/dto.dart';

void main() {
  group('AuthResponse', () {
    test('includes user and tokens', () {
      final user = AuthUser(
        id: 'user123',
        username: 'johndoe',
        email: 'john@example.com',
        emailVerified: true,
        createdAt: DateTime.utc(2024, 1, 1),
        updatedAt: DateTime.utc(2024, 1, 2),
      );
      final response = AuthResponse(
        user: user,
        token: 'access_token',
        expiresAt: DateTime.parse('2024-01-02T00:00:00Z'),
      );

      final json = response.toJson();

      expect(json['token'], 'access_token');
      // AuthUser maps `username` to the BetterAuth wire key `name`.
      expect(json['user']['name'], 'johndoe');
    });
  });
}
