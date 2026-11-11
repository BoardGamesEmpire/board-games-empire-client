import 'package:auth/src/bloc/auth_event.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

void main() {
  const email = 'casey.jones@example.com';
  const password = 'hunter2-secret';
  const username = 'caseyjones';

  const signIn = AuthSignInRequested(email: email, password: password);
  const register = AuthRegisterRequested(
    email: email,
    password: password,
    username: username,
    firstName: 'Casey',
    lastName: 'Jones',
  );

  group('AuthSignInRequested.toString', () {
    test('never prints the password', () {
      final text = signIn.toString();

      expect(text, isNot(contains(password)));
      expect(text, contains('password: <redacted>'));
    });

    test('prints the email only in its redacted form', () {
      final text = signIn.toString();

      expect(text, isNot(contains(email)));
      expect(text, contains(Redaction.redactEmail(email)));
    });
  });

  group('AuthRegisterRequested.toString', () {
    test('never prints the password', () {
      final text = register.toString();

      expect(text, isNot(contains(password)));
      expect(text, contains('password: <redacted>'));
    });

    test('prints the email only in its redacted form', () {
      final text = register.toString();

      expect(text, isNot(contains(email)));
      expect(text, contains(Redaction.redactEmail(email)));
    });

    test('prints username, first name and last name only redacted', () {
      final text = register.toString();

      for (final plain in [username, 'Casey', 'Jones']) {
        expect(text, isNot(contains(plain)), reason: plain);
        expect(text, contains(Redaction.redactName(plain)), reason: plain);
      }
    });

    test('renders omitted names as null', () {
      const bare = AuthRegisterRequested(
        email: email,
        password: password,
        username: username,
      );

      final text = bare.toString();

      expect(text, contains('firstName: null'));
      expect(text, contains('lastName: null'));
    });
  });

  group('string interpolation', () {
    final previous = EquatableConfig.stringify;
    setUp(() => EquatableConfig.stringify = true);
    tearDown(() => EquatableConfig.stringify = previous);

    test('never prints the password, even with EquatableConfig.stringify', () {
      expect('$signIn', isNot(contains(password)));
      expect('$register', isNot(contains(password)));
    });
  });
}
