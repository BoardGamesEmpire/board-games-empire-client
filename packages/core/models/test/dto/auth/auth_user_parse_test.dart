import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:models/dto.dart';

/// Pins parsing against the real BetterAuth `/api/auth/*` payloads
/// (captured from the running backend): `name` maps to `username`, the
/// session envelope is camelCase, and the previously-crashing null-cast
/// (a `username`-keyed model against a `name`-keyed payload) is gone.
void main() {
  // Verbatim sign-up response.
  final signUp = {
    'token': 'iT9ssPm5woBjEtFocoLpvdV7ya31aCJY',
    'user': {
      'name': 'CleverUsername',
      'email': 'john.doe@example.com',
      'emailVerified': false,
      'image': null,
      'createdAt': '2026-06-30T04:12:20.838Z',
      'updatedAt': '2026-06-30T04:12:20.838Z',
      'role': 'user',
      'banned': false,
      'banReason': null,
      'banExpires': null,
      'isAnonymous': false,
      'twoFactorEnabled': false,
      'firstName': null,
      'lastName': null,
      'id': 'GiUKjoaM2Zb6NHRudaIIMC2jG5no5zQg',
    },
  };

  // Verbatim sign-in response (adds the ignored `redirect` envelope key).
  final signIn = {
    'redirect': false,
    'token': 'e3Ne4aXBrRG4wMopvXk2b2Ty6MtJQiEM',
    'user': {
      'name': 'johndoe',
      'email': 'john.doe@example.com',
      'emailVerified': true,
      'image': null,
      'createdAt': '2026-07-15T17:57:00.627Z',
      'updatedAt': '2026-07-15T17:57:00.708Z',
      'role': 'admin',
      'banned': false,
      'banReason': null,
      'banExpires': null,
      'isAnonymous': false,
      'twoFactorEnabled': false,
      'firstName': null,
      'lastName': null,
      'id': 'THlTIVUeZVGvAAbuwFCkczTuklyKUCRh',
    },
  };

  // Verbatim get-session response (camelCase session + user).
  final getSession = {
    'session': {
      'id': 'HKiSSmGZOK83lLNlGdUiCAr71ap7RX4w',
      'ipAddress': '127.0.0.1',
      'userAgent': 'insomnia/13.0.2',
      'expiresAt': '2026-07-22T18:46:08.555Z',
      'userId': 'THlTIVUeZVGvAAbuwFCkczTuklyKUCRh',
      'token': 'KjJTPlVLaxCjZmOBVMv3LjgLDPn3SSoW',
      'createdAt': '2026-07-15T18:46:08.555Z',
      'updatedAt': '2026-07-15T18:46:08.555Z',
    },
    'user': {
      'name': 'johndoe',
      'email': 'john.doe@example.com',
      'emailVerified': true,
      'image': null,
      'createdAt': '2026-07-15T17:57:00.627Z',
      'updatedAt': '2026-07-15T17:57:00.708Z',
      'role': 'admin',
      'banned': false,
      'banReason': null,
      'banExpires': null,
      'isAnonymous': false,
      'twoFactorEnabled': false,
      'firstName': null,
      'lastName': null,
      'id': 'THlTIVUeZVGvAAbuwFCkczTuklyKUCRh',
    },
  };

  group('AuthResponse.fromJson (BetterAuth sign-up/sign-in)', () {
    test('parses sign-up: name → username, no null-cast crash', () {
      final res = AuthResponse.fromJson(signUp);
      expect(res.token, 'iT9ssPm5woBjEtFocoLpvdV7ya31aCJY');
      expect(res.user.username, 'CleverUsername');
      expect(res.user.email, 'john.doe@example.com');
      expect(res.user.emailVerified, isFalse);
      expect(res.user.isAnonymous, isFalse);
      expect(res.user.id, 'GiUKjoaM2Zb6NHRudaIIMC2jG5no5zQg');
    });

    test('parses sign-in and ignores the redirect envelope key', () {
      final res = AuthResponse.fromJson(signIn);
      expect(res.user.username, 'johndoe');
      expect(res.user.emailVerified, isTrue);
    });

    test('user is an AuthUser and widens to UserBase', () {
      final res = AuthResponse.fromJson(signIn);
      expect(res.user, isA<AuthUser>());
      final UserBase base = res.user;
      expect(base.username, 'johndoe');
    });
  });

  group('BgeSessionResponse.fromJson (get-session)', () {
    test('parses camelCase session + user (regression: was snake_case, '
        'would crash on required expiresAt/userId)', () {
      final res = BgeSessionResponse.fromJson(getSession);
      expect(res.session.id, 'HKiSSmGZOK83lLNlGdUiCAr71ap7RX4w');
      expect(res.session.userId, 'THlTIVUeZVGvAAbuwFCkczTuklyKUCRh');
      expect(res.session.expiresAt, DateTime.parse('2026-07-22T18:46:08.555Z'));
      expect(res.session.ipAddress, '127.0.0.1');
      expect(res.user.username, 'johndoe');
    });
  });
}
