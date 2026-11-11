import 'package:bge_test_support/domain.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';

void main() {
  group('testServerIdentity', () {
    test('survives a JSON round trip unchanged', () {
      final identity = testServerIdentity();

      expect(ServerIdentity.fromJson(identity.toJson()), equals(identity));
    });

    test('names testServerUrl as its issuer', () {
      expect(testServerIdentity().issuer, testServerUrl);
    });

    test('advertises the email and password strategy', () {
      expect(testServerIdentity().strategies, [
        testEmailAndPasswordStrategy(),
      ]);
    });
  });

  group('testEmailAndPasswordStrategy', () {
    test('nulls the sign-up endpoint when sign-up is disabled', () {
      final strategy = testEmailAndPasswordStrategy(signUpDisabled: true);

      expect(strategy.signUpDisabled, isTrue);
      expect(strategy.signUpEndpoint, isNull);
    });

    test('is open for sign-up by default', () {
      final strategy = testEmailAndPasswordStrategy();

      expect(strategy.signUpDisabled, isFalse);
      expect(strategy.signUpEndpoint, '$testAuthBasePath/sign-up/email');
    });
  });

  group('testAuthResponse', () {
    test('is user u1 with the fixed token', () {
      final response = testAuthResponse();

      expect(response.user.id, 'u1');
      expect(response.token, 'tok-abc');
    });

    test('varies the user through the nested copyWith', () {
      expect(testAuthResponse().copyWith.user(id: 'u2').user.id, 'u2');
    });
  });
}
