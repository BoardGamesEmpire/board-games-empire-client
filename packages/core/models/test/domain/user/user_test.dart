import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

void main() {
  group('User Model', () {
    test('creates from JSON', () {
      final json = {
        'id': 'user123',
        'firstName': 'John',
        'lastName': 'Doe',
        'username': 'johndoe',
        'email': 'john@example.com',
        'emailVerified': true,
        'image': 'avatar.jpg',
        'createdAt': '2024-01-01T00:00:00Z',
        'updatedAt': '2024-01-02T00:00:00Z',
      };

      final user = User.fromJson(json);

      expect(user.id, 'user123');
      expect(user.firstName, 'John');
      expect(user.lastName, 'Doe');
      expect(user.username, 'johndoe');
      expect(user.email, 'john@example.com');
      expect(user.image, 'avatar.jpg');
    });

    test('serializes to JSON', () {
      final user = User(
        id: 'user123',
        firstName: 'John',
        username: 'johndoe',
        email: 'john@example.com',
        emailVerified: true,
        createdAt: DateTime.utc(2024, 1, 1),
        updatedAt: DateTime.utc(2024, 1, 2),
      );

      final json = user.toJson();

      expect(json['id'], 'user123');
      expect(json['firstName'], 'John');
      expect(json['username'], 'johndoe');
    });

    test('handles nullable fields', () {
      final json = {
        'id': 'user123',
        'username': 'johndoe',
        'email': 'john@example.com',
        'emailVerified': false,
        'createdAt': '2024-01-01T00:00:00Z',
        'updatedAt': '2024-01-02T00:00:00Z',
      };

      final user = User.fromJson(json);

      expect(user.firstName, isNull);
      expect(user.image, isNull);
    });
  });
}
