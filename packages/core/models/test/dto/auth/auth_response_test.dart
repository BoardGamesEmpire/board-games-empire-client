import 'package:test/test.dart';

import 'package:models/dto.dart';

AuthUser _user() => AuthUser(
  id: 'user123',
  username: 'johndoe',
  email: 'john@example.com',
  emailVerified: true,
  createdAt: DateTime.utc(2024, 1, 1),
  updatedAt: DateTime.utc(2024, 1, 2),
);

void main() {
  group('AuthResponse', () {
    test('includes user and tokens', () {
      final response = AuthResponse(
        user: _user(),
        token: 'access_token',
        expiresAt: DateTime.parse('2024-01-02T00:00:00Z'),
      );

      final json = response.toJson();

      expect(json['token'], 'access_token');
      // AuthUser maps `username` to the BetterAuth wire key `name`.
      expect(json['user']['name'], 'johndoe');
    });

    // #291: null is the shape the web path returns. The browser holds the
    // httpOnly cookie, so there is no bearer credential for web to carry.
    group('a null token', () {
      test('is a constructible shape', () {
        final response = AuthResponse(user: _user(), token: null);

        expect(response.token, isNull);
        expect(response.toJson()['token'], isNull);
      });

      test('survives a round trip', () {
        final response = AuthResponse(user: _user(), token: null);

        expect(AuthResponse.fromJson(response.toJson()).token, isNull);
      });

      test('is read from an envelope that omits the field entirely', () {
        final json = Map<String, dynamic>.from(
          AuthResponse(user: _user(), token: null).toJson(),
        )..remove('token');

        expect(AuthResponse.fromJson(json).token, isNull);
      });
    });

    // #291: the generated toString printed the token verbatim, which is what
    // let a credential reach a breadcrumb message or an UncaughtErrorRecord —
    // neither of which redacts anything but emails.
    group('toString', () {
      test('never prints the session token', () {
        final response = AuthResponse(user: _user(), token: 'sess-tok-secret');

        expect(response.toString(), isNot(contains('sess-tok-secret')));
        expect(response.toString(), contains('<redacted>'));
      });

      test('distinguishes an absent token from a redacted one', () {
        final response = AuthResponse(user: _user(), token: null);

        expect(response.toString(), contains('token: null'));
        expect(response.toString(), isNot(contains('<redacted>')));
      });

      test('still carries the fields that make it useful in a log', () {
        final response = AuthResponse(
          user: _user(),
          token: 'sess-tok-secret',
          expiresAt: DateTime.utc(2024, 1, 2),
        );

        expect(response.toString(), contains('AuthResponse'));
        expect(response.toString(), contains('user123'));
        expect(response.toString(), contains('2024-01-02'));
      });
    });
  });

  // #291: BgeSession is the other holder of the raw token — it is what
  // AuthResponse used to be built from, and BgeSessionResponse.toString()
  // reaches it transitively.
  group('BgeSession toString', () {
    BgeSession session() => BgeSession(
      id: 'sess-1',
      token: 'sess-tok-secret',
      expiresAt: DateTime.utc(2099),
      userId: 'user123',
    );

    test('never prints the session token', () {
      expect(session().toString(), isNot(contains('sess-tok-secret')));
      expect(session().toString(), contains('<redacted>'));
    });

    test('is reached through BgeSessionResponse', () {
      final envelope = BgeSessionResponse(session: session(), user: _user());

      expect(envelope.toString(), isNot(contains('sess-tok-secret')));
    });

    test('still carries the session id and user id', () {
      expect(session().toString(), contains('sess-1'));
      expect(session().toString(), contains('user123'));
    });
  });
}
