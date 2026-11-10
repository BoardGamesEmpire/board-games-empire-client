import 'package:models/domain.dart';
import 'package:test/test.dart';

void main() {
  group('UserAuthentication', () {
    test('creates from JSON with enum mapping', () {
      final json = {
        'id': 'auth123',
        'userId': 'user123',
        'email': 'john@example.com',
        'authStrategy': 'Local',
        'emailVerified': true,
        'accountLocked': false,
        'failedLoginAttempts': 0,
        'twoFactorEnabled': false,
        'isExternalUser': false,
      };

      final auth = UserAuthentication.fromJson(json);

      expect(auth.email, 'john@example.com');
      expect(auth.authStrategy, AuthStrategy.local);
      expect(auth.emailVerified, isTrue);
    });

    test('serializes AuthStrategy enum', () {
      const auth = UserAuthentication(
        id: 'auth123',
        userId: 'user123',
        email: 'john@example.com',
        authStrategy: AuthStrategy.google,
        emailVerified: true,
        accountLocked: false,
        failedLoginAttempts: 0,
        twoFactorEnabled: false,
        isExternalUser: true,
      );

      final json = auth.toJson();

      expect(json['authStrategy'], 'Google');
    });
  });
}
