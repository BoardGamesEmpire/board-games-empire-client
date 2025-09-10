import 'package:flutter_test/flutter_test.dart';
import 'package:models/dto.dart';

void main() {
  group('RegisterRequest', () {
    test('serializes all fields', () {
      final request = RegisterRequest(
        email: 'john@example.com',
        password: 'secure_password',
        username: 'johndoe',
        firstName: 'John',
        lastName: 'Doe',
      );

      final json = request.toJson();

      expect(json['email'], 'john@example.com');
      expect(json['username'], 'johndoe');
      expect(json['firstName'], 'John');
      expect(json['lastName'], 'Doe');
    });
  });
}
