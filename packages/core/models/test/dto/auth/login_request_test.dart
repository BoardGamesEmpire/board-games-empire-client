import 'package:flutter_test/flutter_test.dart';
import 'package:models/dto.dart';

void main() {
  group('LoginRequest', () {
    test('serializes with device info', () {
      final request = LoginRequest(
        email: 'john@example.com',
        password: 'secure_password',
        deviceIdentifier: 'device123',
        deviceInfo: {'platform': 'iOS', 'version': '15.0'},
      );

      final json = request.toJson();

      expect(json['email'], 'john@example.com');
      expect(json['deviceIdentifier'], 'device123');
      expect(json['deviceInfo']['platform'], 'iOS');
    });
  });
}
